defmodule Auth2ApiEx.Handlers.OpenAI do
  @moduledoc """
  Handlers for OpenAI-compatible endpoints:
  - POST /v1/chat/completions
  - POST /v1/responses

  Routes models through the Provider Registry:
  - Codex models → passthrough to Codex API (native OpenAI Responses format)
  - Anthropic models → translate to Anthropic Messages API
  """

  alias Auth2ApiEx.{Config, Accounts.Manager}
  alias Auth2ApiEx.Utils.{HTTP, SessionKey}

  alias Auth2ApiEx.Upstream.{
    Translator,
    Cloaking,
    AnthropicAPI,
    CodexAPI,
    CodexResponses,
    Streaming
  }

  alias Auth2ApiEx.Providers.Registry

  import Auth2ApiEx.PlugHelpers, only: [send_json: 3]

  @doc """
  Handle POST /v1/chat/completions — OpenAI Chat Completions format.
  Codex models are not supported on this endpoint; clients should use /v1/responses.
  """
  @spec handle_chat_completions(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def handle_chat_completions(conn, config) do
    body = conn.assigns[:parsed_body] || %{}

    messages = body["messages"]

    if !is_list(messages) || length(messages) == 0 do
      send_json(conn, 400, %{
        error: %{message: "messages is required and must be a non-empty array"}
      })
    else
      model = Translator.resolve_model(body["model"] || "claude-sonnet-4-6")

      # Check if Codex model — redirect to /v1/responses
      registry = conn.assigns[:registry]

      if registry do
        provider = Registry.for_model(registry, model)

        if provider.id == :codex do
          send_json(conn, 400, %{
            error: %{message: "Codex models require the /v1/responses endpoint"}
          })
        else
          do_chat_completions(conn, config, body, model)
        end
      else
        do_chat_completions(conn, config, body, model)
      end
    end
  rescue
    e ->
      require Logger
      Logger.error("Handler error: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
      send_json(conn, 500, %{error: %{message: "Internal server error"}})
  end

  defp do_chat_completions(conn, config, body, model) do
    stream = !!body["stream"]

    structured =
      get_in(body, ["response_format", "type"]) == "json_object" ||
        get_in(body, ["response_format", "type"]) == "json_schema"

    translated_body = Translator.openai_to_anthropic(body)

    if Config.debug_level?(config.debug, :verbose) do
      require Logger

      Logger.debug(
        "[DEBUG] Translated OpenAI->Anthropic body (before cloaking): #{Jason.encode!(translated_body, pretty: true)}"
      )
    end

    session_key = SessionKey.from_request_or_api_key(conn, body)
    mgr = get_manager()

    HTTP.proxy_with_retry("ChatCompletions", conn, config, mgr,
      session_key: session_key,
      model: model,
      error_adapter: &HTTP.openai_error_body/2,
      upstream: fn account ->
        anthropic_body = Cloaking.apply_cloaking(translated_body, conn, account, config)

        AnthropicAPI.call_anthropic_messages(
          body: anthropic_body,
          conn: conn,
          account: account,
          config: config,
          structured: structured
        )
      end,
      success: fn upstream, account ->
        if stream do
          include_usage = get_in(body, ["stream_options", "include_usage"]) != false

          {:ok, state_agent} =
            Agent.start_link(fn -> Translator.create_stream_state(model, include_usage) end)

          result =
            Streaming.handle_streaming_response(upstream, conn,
              receive_timeout: config.timeouts.stream_messages_ms,
              on_event: fn event, data, usage ->
                state = Agent.get(state_agent, & &1)
                {chunks, new_state} = Translator.anthropic_sse_to_chat(event, data, state, usage)
                Agent.update(state_agent, fn _ -> new_state end)
                Enum.map(chunks, fn c -> "data: #{c}\n\n" end)
              end
            )

          Agent.stop(state_agent)

          if result.completed do
            Manager.record_success(mgr, account.token.email, result.usage,
              model: model,
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
            model: model,
            provider: account.provider || account.token.provider || "anthropic"
          )

          send_json(conn, 200, Translator.anthropic_to_openai(anthropic_resp, model))
        end
      end
    )
  end

  @doc """
  Handle POST /v1/responses — OpenAI Responses API format.

  Routes models through the Provider Registry:
  - Anthropic models: translate to Anthropic Messages, cloak, call, then translate back
  - Codex models: passthrough to Codex API (native OpenAI Responses format)
  """
  @spec handle_responses(Plug.Conn.t(), Config.t()) :: Plug.Conn.t()
  def handle_responses(conn, config) do
    body = conn.assigns[:parsed_body] || %{}

    if !body["input"] && !body["messages"] do
      send_json(conn, 400, %{error: %{message: "input is required"}})
    else
      model = Translator.resolve_model(body["model"] || "claude-sonnet-4-6")

      registry = conn.assigns[:registry]

      if registry do
        provider = Registry.for_model(registry, model)

        if provider.id == :codex do
          handle_codex_responses(conn, config, body, provider)
        else
          handle_anthropic_responses(conn, config, body, model)
        end
      else
        handle_anthropic_responses(conn, config, body, model)
      end
    end
  rescue
    e ->
      require Logger
      Logger.error("Responses handler error: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
      send_json(conn, 500, %{error: %{message: "Internal server error"}})
  end

  defp handle_anthropic_responses(conn, config, body, model) do
    stream = !!body["stream"]

    structured =
      get_in(body, ["text", "format", "type"]) == "json_object" ||
        get_in(body, ["text", "format", "type"]) == "json_schema"

    translated_body = Translator.responses_to_anthropic(body)

    session_key = SessionKey.from_request_or_api_key(conn, body)
    mgr = get_manager()

    HTTP.proxy_with_retry("Responses", conn, config, mgr,
      session_key: session_key,
      model: model,
      error_adapter: &HTTP.openai_error_body/2,
      upstream: fn account ->
        anthropic_body = Cloaking.apply_cloaking(translated_body, conn, account, config)

        AnthropicAPI.call_anthropic_messages(
          body: anthropic_body,
          conn: conn,
          account: account,
          config: config,
          structured: structured
        )
      end,
      success: fn upstream, account ->
        if stream do
          {:ok, state_agent} = Agent.start_link(fn -> Translator.make_responses_state() end)

          result =
            Streaming.handle_streaming_response(upstream, conn,
              receive_timeout: config.timeouts.stream_messages_ms,
              on_event: fn event, data, usage ->
                state = Agent.get(state_agent, & &1)

                {events, new_state} =
                  Translator.anthropic_sse_to_responses(event, data, state, model, usage)

                Agent.update(state_agent, fn _ -> new_state end)
                events
              end
            )

          Agent.stop(state_agent)

          if result.completed do
            Manager.record_success(mgr, account.token.email, result.usage,
              model: model,
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
            model: model,
            provider: account.provider || account.token.provider || "anthropic"
          )

          send_json(conn, 200, Translator.anthropic_to_responses(anthropic_resp, model))
        end
      end
    )
  end

  defp handle_codex_responses(conn, config, body, provider) do
    # Codex requires stream=true upstream. The client's original stream intent
    # decides whether we pass SSE through or drain it locally into JSON.

    # Minimal normalization matching Node.js proxyCodexResponses:
    #   normaliseCodexResponsesBody → delete max_output_tokens + parallel_tool_calls → stream=true
    normalized_body =
      body
      |> CodexAPI.minimal_responses_body()
    stream = !!body["stream"]
    manager = provider.manager
    session_key = SessionKey.from_request_or_api_key(conn, body)
    model = Translator.resolve_model(body["model"] || "codex")

    require Logger
    input_len = if is_binary(body["input"]), do: String.length(body["input"]), else: 0
    msg_count = if is_list(body["input"]), do: length(body["input"]), else: 0

    Logger.info(
      "[codex] /v1/responses model=#{model} stream=#{stream} input_len=#{input_len} input_msgs=#{msg_count}"
    )
    test_plug =
      conn.assigns[:test_plug] ||
      Process.get(:__auth2api_ex_codex_plug__) ||
      Application.get_env(:auth2api_ex, :test_plug)

    HTTP.proxy_with_retry("CodexResponses", conn, config, manager,
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
            stream: stream,
            api_key_hash: SessionKey.api_key_hash(conn)
          ] ++ opts
        )
      end,
      success: fn upstream, account ->
        if stream do
          Logger.info(
            "[codex] starting stream model=#{model} upstream_status=#{upstream.status}"
          )

          result =
            Streaming.handle_streaming_response(upstream, conn,
              receive_timeout: config.timeouts.stream_messages_ms
            )

          if result.completed do
            Logger.info(
              "[codex] stream completed model=#{model} tokens_in=#{result.usage.input_tokens} tokens_out=#{result.usage.output_tokens}"
            )

            record_codex_utilization(manager, account, upstream)
            Manager.record_success(manager, account.token.email, result.usage,
              model: model,
              provider: account.provider || account.token.provider || "codex"
            )
          else
            reason = if result.client_disconnected, do: "client_disconnected", else: "stream_terminated"
            Logger.warning("[codex] stream incomplete model=#{model} reason=#{reason}")

            if !result.client_disconnected do
              Manager.record_failure(
                manager,
                account.token.email,
                :network,
                "stream terminated before completion"
              )
            end
          end

          result.conn
        else
          handle_nonstream_codex_response(conn, upstream, manager, account, model)
        end
      end
    )
  end

  defp handle_nonstream_codex_response(conn, upstream, manager, account, model) do
    record_codex_utilization(manager, account, upstream)

    case upstream.body do
      body when is_binary(body) ->
        drained = CodexResponses.drain_sse_body(body)

        case CodexResponses.build_response(drained, model) do
          {:ok, response} ->
            Manager.record_success(manager, account.token.email, CodexResponses.usage(response),
              model: model,
              provider: account.provider || account.token.provider || "codex"
            )

            send_json(conn, 200, response)

          {:error, message} ->
            Manager.record_failure(manager, account.token.email, :server, message)
            send_json(conn, 502, %{error: %{message: message, type: "upstream_error"}})
        end

      body when is_map(body) ->
        Manager.record_success(manager, account.token.email, CodexResponses.usage(body),
          model: model,
          provider: account.provider || account.token.provider || "codex"
        )

        send_json(conn, 200, body)
    end
  end

  defp record_codex_utilization(manager, account, upstream) do
    info = HTTP.parse_codex_utilization(upstream.headers)

    if info.utilization_5h || info.utilization_7d do
      Manager.record_utilization(manager, account.token.email, info)
    end
  end

  defp get_manager do
    Process.get(:__auth2api_ex_manager__, Manager)
  end
end
