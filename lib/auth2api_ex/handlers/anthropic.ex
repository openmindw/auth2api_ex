defmodule Auth2ApiEx.Handlers.Anthropic do
  @moduledoc """
  Handlers for Anthropic native passthrough endpoints:
  - POST /v1/messages
  - POST /v1/messages/count_tokens

  Routes models through the Provider Registry — Codex models are rejected
  on Anthropic-native endpoints.
  """

  alias Auth2ApiEx.{Config, Accounts.Manager}
  alias Auth2ApiEx.Utils.{HTTP, SessionKey}
  alias Auth2ApiEx.Upstream.{Cloaking, AnthropicAPI, Streaming, Translator}
  alias Auth2ApiEx.Providers.Registry

  import Auth2ApiEx.PlugHelpers, only: [send_json: 3]

  @doc """
  Handle POST /v1/messages — Anthropic native format passthrough.
  Codex models return 400 directing to /v1/responses.
  """
  @spec handle_messages(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def handle_messages(conn, config) do
    body = conn.assigns[:parsed_body] || %{}

    messages = body["messages"]

    if !is_list(messages) || length(messages) == 0 do
      send_json(conn, 400, %{
        error: %{message: "messages is required and must be a non-empty array"}
      })
    else
      if Config.debug_level?(config.debug, :verbose) do
        require Logger
        Logger.debug("[DEBUG] Incoming /v1/messages body: #{Jason.encode!(body, pretty: true)}")
      end

      # Check for Codex models — not supported on this endpoint
      check_codex_model(conn, body) || do_messages(conn, config, body)
    end
  rescue
    e ->
      require Logger
      Logger.error("Messages handler error: #{Exception.message(e)}")
      send_json(conn, 500, %{error: %{message: "Internal server error"}})
  end

  defp do_messages(conn, config, body) do
    stream = !!body["stream"]
    session_key = SessionKey.from_request_or_api_key(conn, body)
    mgr = get_manager()

    HTTP.proxy_with_retry("Messages", conn, config, mgr,
      session_key: session_key,
      model: body["model"],
      upstream: fn account ->
        anthropic_body = Cloaking.apply_cloaking(body, conn, account, config)

        AnthropicAPI.call_anthropic_messages(
          body: anthropic_body,
          conn: conn,
          account: account,
          config: config
        )
      end,
      success: fn upstream, account ->
        if stream do
          result =
            Streaming.handle_streaming_response(upstream, conn,
              receive_timeout: config.timeouts.stream_messages_ms
            )

          if result.completed do
            Manager.record_success(mgr, account.token.email, result.usage,
              model: body["model"],
              provider: account.provider || account.token.provider || "anthropic"
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
          anthropic_resp = upstream.body

          Manager.record_success(mgr, account.token.email, Manager.extract_usage(anthropic_resp),
            model: body["model"],
            provider: account.provider || account.token.provider || "anthropic"
          )

          record_anthropic_utilization(mgr, account, upstream)

          conn =
            Enum.reduce(
              Auth2ApiEx.Upstream.ResponseFilter.sanitize_headers(upstream.headers),
              conn,
              fn {k, v}, c ->
                Plug.Conn.put_resp_header(c, k, v)
              end
            )

          send_json(conn, 200, anthropic_resp)
        end
      end
    )
  end

  @doc """
  Handle POST /v1/messages/count_tokens — passthrough.
  Codex models return 501 (not supported).
  """
  @spec handle_count_tokens(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def handle_count_tokens(conn, config) do
    body = conn.assigns[:parsed_body] || %{}

    # Check for Codex models — count_tokens not supported
    if check_codex_count_tokens(conn, body), do: conn, else: do_count_tokens(conn, config, body)
  rescue
    e ->
      require Logger
      Logger.error("Count tokens error: #{Exception.message(e)}")
      send_json(conn, 500, %{error: %{message: "Internal server error"}})
  end

  defp do_count_tokens(conn, config, body) do
    session_key = SessionKey.from_request_or_api_key(conn, body)
    mgr = get_manager()

    HTTP.proxy_with_retry("CountTokens", conn, config, mgr,
      session_key: session_key,
      model: body["model"],
      upstream: fn account ->
        AnthropicAPI.call_anthropic_count_tokens(
          conn: conn,
          account: account,
          config: config,
          body: body
        )
      end,
      success: fn upstream, account ->
        Manager.record_success(mgr, account.token.email, nil,
          model: body["model"],
          provider: account.provider || account.token.provider || "anthropic"
        )

        data = upstream.body
        send_json(conn, 200, data)
      end
    )
  end

  # Check if the request model is a Codex model and return 400 directing to /v1/responses.
  # Returns the conn if it halted, nil otherwise.
  defp check_codex_model(conn, body) do
    model = Translator.resolve_model(body["model"] || "")
    registry = conn.assigns[:registry]

    if registry && model != "" do
      provider = Registry.for_model(registry, model)

      if provider.id == :codex do
        send_json(conn, 400, %{
          error: %{
            message: "Codex models are not supported on /v1/messages. Use /v1/responses instead."
          }
        })
      end
    end
  end

  # Check for Codex models on count_tokens — return 501.
  defp check_codex_count_tokens(conn, body) do
    model = Translator.resolve_model(body["model"] || "")
    registry = conn.assigns[:registry]

    if registry && model != "" do
      provider = Registry.for_model(registry, model)

      if provider.id == :codex do
        send_json(conn, 501, %{
          error: %{message: "Token counting is not supported for Codex models"}
        })

        true
      else
        false
      end
    else
      false
    end
  end

  defp record_anthropic_utilization(mgr, account, upstream) do
    info = HTTP.parse_anthropic_utilization(upstream.headers)

    if info.utilization_5h || info.utilization_7d do
      Manager.record_utilization(mgr, account.token.email, info)
    end
  end

  defp get_manager do
    Process.get(:__auth2api_ex_manager__, Manager)
  end
end
