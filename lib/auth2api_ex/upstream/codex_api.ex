defmodule Auth2ApiEx.Upstream.CodexAPI do
  @moduledoc """
  HTTP client for the Codex backend API.

  Calls POST /codex/responses on chatgpt.com/backend-api with headers
  matching the official codex CLI (codex-rs).
  """

  alias Auth2ApiEx.Upstream.CodexInputFilter
  alias Auth2ApiEx.Utils.SessionKey

  @base_url "https://chatgpt.com/backend-api"
  @responses_path "/codex/responses"
  @default_originator "codex_cli_rs"
  @default_cli_version "0.125.0"

  @doc """
  Call the Codex /codex/responses endpoint.

  The `body` is expected to already be normalized via `normalize_body/1`
  (handlers do this so `stream` is consistent across the call site and
  the request itself). We re-normalize defensively to remain a safe
  public entry point.
  """
  def call_codex_responses(opts) do
    body = Keyword.fetch!(opts, :body)
    account = Keyword.fetch!(opts, :account)
    config = Keyword.fetch!(opts, :config)

    # Only apply full normalization when the body hasn't been pre-processed
    # by the caller (e.g., handle_codex_responses already uses minimal_responses_body).
    normalized =
      if Keyword.get(opts, :skip_normalize, false) do
        body
      else
        normalize_body(body)
      end
    # If the body contains prompt_cache_key, reuse it as the upstream session
    # key so ChatGPT/Codex sees a stable session id. Short client keys are
    # preserved; overlong keys are compressed to fit the upstream limit.
    headers = build_headers(account, true, config)

    pc_key = SessionKey.prompt_cache_key(body)
    upstream_pc_key = if pc_key, do: SessionKey.upstream_prompt_cache_key(pc_key), else: nil

    headers =
      if upstream_pc_key && upstream_pc_key != "" do
        headers ++ [{"session_id", upstream_pc_key}, {"conversation_id", upstream_pc_key}]
      else
        headers
      end

    # Body always has stream=true enforced for the upstream. Use the :stream
    # opt only to choose whether Req should hand the caller async chunks or a
    # buffered SSE body that the handler can drain into JSON.
    stream = Keyword.get(opts, :stream, true)
    url = "#{@base_url}#{@responses_path}"

    timeout_ms =
      if stream,
        do: config.timeouts.stream_messages_ms,
        else: config.timeouts.messages_ms

    req_opts = [
      headers: headers,
      json: normalized,
      receive_timeout: timeout_ms,
      connect_options: [
        timeout: 30_000,
        protocols: [:http1]
      ],
      # Prevent connection reuse — a stuck HTTP/1.1 stream must not
      # block subsequent requests waiting for the same pooled connection.
      pool_max_idle_time: 0,
      pool_timeout: 10_000
    ]

    req_opts = if stream, do: Keyword.put(req_opts, :into, :self), else: req_opts

    # Support Req.Test plug stubs in test mode
    req_opts = maybe_put_plug(req_opts, opts)

    Req.post(url, req_opts)
  end

  defp maybe_put_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  @doc """
  Normalize the Codex request body — thin wrapper around transform_body/2.
  Maintains backward compatibility: stream defaults to true, store to false,
  instructions to "".
  """
  def normalize_body(body) when is_map(body), do: transform_body(body, [])
  def normalize_body(body), do: body

  @responses_unsupported_fields [
    "max_output_tokens",
    "parallel_tool_calls"
  ]

  @doc """
  Minimal normalization for /v1/responses Codex path — matches Node.js
  `proxyCodexResponses` behaviour:

    normaliseCodexResponsesBody(body);  // set defaults
    delete body.max_output_tokens;
    delete body.parallel_tool_calls;
    body.stream = true;

  No aggressive input filtering, call_id rewriting, or system message
  extraction — the request body stays as close to the client's intent
  as possible.
  """
  def minimal_responses_body(body) when is_map(body) do
    body
    |> minimal_set_defaults()
    |> Map.drop(@responses_unsupported_fields)
    |> Map.put("stream", true)
  end

  def minimal_responses_body(body), do: body

  defp minimal_set_defaults(body) do
    body
    |> put_if_missing("stream", true)
    |> put_if_missing("store", false)
    |> put_if_missing("instructions", "")
  end

  defp put_if_missing(map, key, value) do
    if Map.has_key?(map, key), do: map, else: Map.put(map, key, value)
  end

  @doc """
  Transform a Codex request body to strip unsupported fields and enforce
  protocol-level requirements (stream=true, store=false, etc.).

  Options:
    - is_codex_cli: boolean (default false). When true, system messages in
      input are preserved (the Codex CLI handles them natively).
    - is_compact: boolean (default false). When true, store and stream
      fields are stripped entirely rather than forced.
  """
  @spec transform_body(map(), keyword()) :: map()
  def transform_body(body, opts \\ [])

  def transform_body(body, opts) when is_map(body) do
    is_codex_cli = Keyword.get(opts, :is_codex_cli, false)
    is_compact = Keyword.get(opts, :is_compact, false)

    body
    |> strip_unsupported()
    |> force_store_and_stream(is_compact)
    |> convert_functions_to_tools()
    |> convert_function_call_to_tool_choice()
    |> normalize_input()
    |> CodexInputFilter.normalize_tool_role_messages()
    |> CodexInputFilter.fix_call_id_prefix()
    |> CodexInputFilter.filter_input()
    |> extract_system_messages(is_codex_cli)
    |> trim_model()
    |> inject_default_instructions()
  end

  def transform_body(body, _opts), do: body

  # ── Unsupported field stripping ──

  @unsupported_fields [
    "max_output_tokens",
    "max_completion_tokens",
    "temperature",
    "top_p",
    "frequency_penalty",
    "presence_penalty",
    "user",
    "metadata",
    "prompt_cache_retention",
    "safety_identifier",
    "stream_options"
  ]

  defp strip_unsupported(body) do
    Map.drop(body, @unsupported_fields)
  end

  # ── store / stream enforcement ──

  defp force_store_and_stream(body, true = _is_compact) do
    body
    |> Map.delete("store")
    |> Map.delete("stream")
  end

  defp force_store_and_stream(body, false) do
    body
    |> Map.put("store", false)
    |> Map.put("stream", true)
  end

  # ── functions → tools ──

  defp convert_functions_to_tools(body) do
    case body do
      %{"functions" => functions} when is_list(functions) ->
        tools =
          Enum.map(functions, fn f ->
            %{"type" => "function", "function" => f}
          end)

        body
        |> Map.delete("functions")
        |> Map.put("tools", tools)

      _ ->
        body
    end
  end

  # ── function_call → tool_choice ──

  defp convert_function_call_to_tool_choice(body) do
    case body do
      %{"function_call" => fc} when is_binary(fc) ->
        body
        |> Map.delete("function_call")
        |> Map.put("tool_choice", fc)

      %{"function_call" => %{"name" => name}} ->
        body
        |> Map.delete("function_call")
        |> Map.put("tool_choice", %{"type" => "function", "name" => name})

      _ ->
        body
    end
  end

  # ── input normalization ──

  defp normalize_input(%{"input" => input} = body) when is_binary(input) do
    trimmed = String.trim(input)

    wrapped =
      if trimmed == "" do
        []
      else
        [%{"type" => "message", "role" => "user", "content" => input}]
      end

    Map.put(body, "input", wrapped)
  end

  defp normalize_input(body), do: body

  # ── system message extraction ──

  defp extract_system_messages(%{"input" => input} = body, false = _is_codex_cli)
       when is_list(input) do
    {system_texts, remaining} = split_system_messages(input, [], [])

    if system_texts == [] do
      body
    else
      extracted = Enum.join(system_texts, "\n\n")

      body =
        body
        |> Map.put("input", remaining)

      existing = Map.get(body, "instructions", "")

      instructions =
        if String.trim(existing) == "" do
          extracted
        else
          extracted <> "\n\n" <> existing
        end

      Map.put(body, "instructions", instructions)
    end
  end

  defp extract_system_messages(body, _is_codex_cli), do: body

  defp split_system_messages([], texts, remaining),
    do: {Enum.reverse(texts), Enum.reverse(remaining)}

  defp split_system_messages([item | rest], texts, remaining) do
    case item do
      %{"role" => "system"} = msg ->
        content = extract_text_content(msg["content"])
        split_system_messages(rest, [content | texts], remaining)

      _ ->
        split_system_messages(rest, texts, [item | remaining])
    end
  end

  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_text_content(_), do: ""

  # ── model trim ──

  defp trim_model(%{"model" => model} = body) do
    trimmed = String.trim(model)

    if trimmed == "" do
      Map.delete(body, "model")
    else
      Map.put(body, "model", trimmed)
    end
  end

  defp trim_model(body), do: body

  # ── default instructions injection (P0 original behavior) ──

  defp inject_default_instructions(body) do
    case Map.get(body, "instructions") do
      nil -> Map.put(body, "instructions", "")
      _ -> body
    end
  end

  @doc """
  Build headers for the Codex API request.
  Matches the official codex CLI's headers — header casing and order
  mirror the Node.js `codex-provider-ref` build (which mirrors codex-rs).

  Order: Content-Type, Authorization, Accept, User-Agent, originator,
  version, [ChatGPT-Account-ID], [OpenAI-Beta].
  """
  def build_headers(account, stream, config) do
    codex_cfg = get_in(config.cloaking, [:codex]) || %{}

    base = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{account.token.access_token}"},
      {"Accept", if(stream, do: "text/event-stream", else: "application/json")},
      {"User-Agent", build_user_agent(codex_cfg)},
      # `originator` and `version` are lowercase per codex-rs CLI.
      {"originator", Map.get(codex_cfg, "originator", @default_originator)},
      {"version", Map.get(codex_cfg, "cli-version", @default_cli_version)}
    ]

    base =
      case account.chatgpt_account_id do
        nil -> base
        "" -> base
        id -> base ++ [{"ChatGPT-Account-ID", id}]
      end

    case Map.get(codex_cfg, "openai-beta") do
      nil -> base
      beta -> base ++ [{"OpenAI-Beta", beta}]
    end
  end

  # Matching sub2api DefaultOpenAICodexUserAgent — codex-tui is less likely
  # to be flagged than generic codex_cli_rs by newer Cloudflare rules.
  @default_ua "codex-tui/0.125.0 (Ubuntu 22.4.0; x86_64) xterm-256color (codex-tui; 0.125.0)"

  defp build_user_agent(codex_cfg) do
    case Map.get(codex_cfg, "user-agent") do
      nil ->
        @default_ua

      ua ->
        ua
    end
  end

  defp detect_platform do
    arch_str = :erlang.system_info(:system_architecture) |> List.to_string()

    platform =
      case :os.type() do
        {:win32, _} -> "windows"
        {:unix, :darwin} -> "macos"
        _ -> "linux"
      end

    arch =
      cond do
        String.contains?(arch_str, "arm") or String.contains?(arch_str, "aarch") -> "arm64"
        true -> "x86_64"
      end

    {platform, arch}
  end
end
