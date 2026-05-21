defmodule Auth2ApiEx.Handlers.OpenAIImages do
  @moduledoc """
  Handlers for OpenAI Images API endpoints:

    * POST /v1/images/generations — image generation
    * POST /v1/images/edits — image edit (multipart)

  Routes via Codex OAuth path only (single-account proxy).  Auth / retry /
  sticky-session are delegated to `HTTP.proxy_with_retry`.
  """

  alias Auth2ApiEx.{Config, Accounts.Manager}
  alias Auth2ApiEx.Utils.{HTTP, SessionKey}
  alias Auth2ApiEx.Upstream.{Streaming, CodexAPI}
  alias Auth2ApiEx.Upstream.Images.{Request, Codex}

  import Auth2ApiEx.PlugHelpers, only: [send_json: 3]

  @doc """
  Handle POST /v1/images/generations.
  """
  @spec handle_generations(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def handle_generations(conn, config) do
    body = conn.assigns[:parsed_body] || %{}
    images_cfg = config.images

    case Request.parse_generations(body, images_cfg.default_model) do
      {:ok, req} ->
        do_images(conn, config, req)

      {:error, "unsupported_model"} ->
        send_json(conn, 400, %{
          error: %{
            message: "Model must be gpt-image-*",
            type: "invalid_request_error",
            code: "unsupported_model"
          }
        })

      {:error, reason} ->
        send_json(conn, 400, %{error: %{message: reason, type: "invalid_request_error"}})
    end
  end

  @doc """
  Handle POST /v1/images/edits.
  """
  @spec handle_edits(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def handle_edits(conn, config) do
    images_cfg = config.images

    case Request.parse_edits(conn, images_cfg.default_model) do
      {:ok, req} ->
        # Enforce OAuth n=1 limit for edits
        req = %{req | n: min(req.n, images_cfg.edits_oauth_max_n)}
        do_images(conn, config, req)

      {:error, "unsupported_model"} ->
        send_json(conn, 400, %{
          error: %{
            message: "Model must be gpt-image-*",
            type: "invalid_request_error",
            code: "unsupported_model"
          }
        })

      {:error, reason} ->
        send_json(conn, 400, %{error: %{message: reason, type: "invalid_request_error"}})
    end
  end

  # ── Shared proxy path ──

  defp do_images(conn, config, req) do
    images_cfg = config.images

    if total_upload_size(req) > images_cfg.max_upload_bytes do
      send_json(conn, 413, %{error: %{message: "Uploaded images exceed maximum size"}})
    else
      do_images_ok(conn, config, req, images_cfg)
    end
  end

  defp do_images_ok(conn, config, req, images_cfg) do
    stream = req.stream
    session_key = SessionKey.from_request_or_api_key(conn, conn.assigns[:parsed_body] || %{})
    mgr = get_manager()
    model = req.model

    upstream_codex_model = images_cfg.upstream_codex_model
    codex_body = Codex.build_request(req, upstream_codex_model)
    normalized_body = CodexAPI.normalize_body(codex_body)
    test_plug =
      conn.assigns[:test_plug] ||
      Process.get(:__auth2api_ex_codex_plug__) ||
      Application.get_env(:auth2api_ex, :test_plug)

    HTTP.proxy_with_retry("OpenAIImages", conn, config, mgr,
      session_key: session_key,
      model: model,
      error_adapter: &HTTP.openai_error_body/2,
      upstream: fn account ->
        opts = if test_plug, do: [plug: test_plug], else: []

        CodexAPI.call_codex_responses(
          [
            body: normalized_body,
            account: account,
            config: config,
            api_key_hash: SessionKey.api_key_hash(conn)
          ] ++ opts
        )
      end,
      success: fn upstream, account ->
        if stream do
          result =
            Streaming.handle_streaming_response(upstream, conn,
              receive_timeout: config.timeouts.stream_messages_ms,
              on_event: &Codex.on_sse_event/3
            )

          if result.completed do
            Manager.record_success(mgr, account.token.email, result.usage,
              model: config.images.upstream_codex_model,
              provider: account.provider || account.token.provider || "codex"
            )
          else
            if !result.client_disconnected do
              Manager.record_failure(
                mgr,
                account.token.email,
                :network,
                "stream terminated before completion"
              )
            end
          end

          result.conn
        else
          handle_nonstream_images(conn, config, upstream, mgr, account, req)
        end
      end
    )
  end

  # Non-stream: intercept SSE chunks, aggregate, then reply with JSON.
  defp handle_nonstream_images(conn, config, upstream, mgr, account, req) do
    {:ok, agent} = Agent.start_link(fn -> %{images: []} end)

    _result =
      Streaming.handle_streaming_response(upstream, conn,
        receive_timeout: config.timeouts.stream_messages_ms,
        write_chunk: fn _chunk -> {:ok, nil} end,
        on_event: fn event, data, _usage ->
          case Codex.aggregate_event(event, data, Agent.get(agent, & &1)) do
            {:cont, _chunk, new_acc} ->
              Agent.update(agent, fn _ -> new_acc end)
              []

            {:done, nil, new_acc} ->
              Agent.update(agent, fn _ -> new_acc end)
              []

            {:done, {:error, err_data}, _new_acc} ->
              Agent.update(agent, fn acc -> Map.put(acc, :error, err_data) end)
              []
          end
        end
      )

    acc = Agent.get(agent, & &1)
    Agent.stop(agent)

    if acc[:error] do
      Manager.record_failure(mgr, account.token.email, :server, "image generation failed")

      send_json(conn, 502, %{error: %{message: "Image generation failed", type: "upstream_error"}})
    else
      images = acc[:images] || []

      Manager.record_success(mgr, account.token.email, nil,
        model: config.images.upstream_codex_model,
        provider: account.provider || account.token.provider || "codex"
      )

      resp = Codex.build_openai_images_response(images, req.response_format)
      send_json(conn, 200, resp)
    end
  end

  defp total_upload_size(req) do
    upload_size = Enum.reduce(req.uploads, 0, fn u, acc -> acc + byte_size(u.data) end)
    mask_size = if req.mask_upload, do: byte_size(req.mask_upload.data), else: 0
    upload_size + mask_size
  end

  defp get_manager do
    Process.get(:__auth2api_ex_manager__, Manager)
  end
end
