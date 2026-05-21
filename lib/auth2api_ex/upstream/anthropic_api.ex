defmodule Auth2ApiEx.Upstream.AnthropicAPI do
  @moduledoc """
  Upstream Anthropic API client.
  Builds request headers with Claude Code CLI cloaking and makes HTTP calls.
  """

  alias Auth2ApiEx.Utils.Common

  # API中转地址，对齐Node.js版本；OAuth授权用 platform.claude.com，见 oauth.ex
  @base_url "https://api.anthropic.com"
  @default_cli_version "2.1.88"
  @default_entrypoint "cli"

  # Session ID management
  @session_ttl_min 30 * 60 * 1000
  @session_ttl_max 300 * 60 * 1000

  # ── Session ID management ──

  @doc """
  Get or create a session ID for an API key hash.
  Session IDs expire after a random TTL (30-300 minutes).
  """
  @spec get_session_id(String.t()) :: String.t()
  def get_session_id(api_key_hash) do
    now = System.system_time(:millisecond)

    case :ets.lookup(:auth2api_ex_sessions, api_key_hash) do
      [{^api_key_hash, id, last_used, ttl}] when now - last_used < ttl ->
        :ets.insert(:auth2api_ex_sessions, {api_key_hash, id, now, ttl})
        id

      _ ->
        # Clean up expired sessions
        cleanup_expired_sessions(now)

        id = UUID.uuid4()
        ttl = @session_ttl_min + :rand.uniform(@session_ttl_max - @session_ttl_min)
        :ets.insert(:auth2api_ex_sessions, {api_key_hash, id, now, ttl})
        id
    end
  end

  defp cleanup_expired_sessions(now) do
    :ets.foldl(
      fn {key, _id, last_used, ttl}, acc ->
        if now - last_used >= ttl do
          :ets.delete(:auth2api_ex_sessions, key)
        end

        acc
      end,
      :ok,
      :auth2api_ex_sessions
    )
  end

  # ── Beta header construction ──

  defp build_beta_header(model, structured) do
    is_haiku = String.contains?(model, "haiku")

    cond do
      is_haiku and structured ->
        "oauth-2025-04-20,interleaved-thinking-2025-05-14,redact-thinking-2026-02-12,context-management-2025-06-27,prompt-caching-scope-2026-01-05,structured-outputs-2025-12-15"

      is_haiku ->
        "oauth-2025-04-20,interleaved-thinking-2025-05-14,redact-thinking-2026-02-12,context-management-2025-06-27,prompt-caching-scope-2026-01-05,claude-code-20250219"

      structured ->
        "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,redact-thinking-2026-02-12,context-management-2025-06-27,prompt-caching-scope-2026-01-05,advanced-tool-use-2025-11-20,effort-2025-11-24,structured-outputs-2025-12-15"

      true ->
        "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,redact-thinking-2026-02-12,context-management-2025-06-27,prompt-caching-scope-2026-01-05,advanced-tool-use-2025-11-20,effort-2025-11-24"
    end
  end

  # ── Stainless SDK headers ──

  defp get_stainless_arch do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      String.contains?(arch, "aarch64") or String.contains?(arch, "arm") -> "arm64"
      String.contains?(arch, "x86_64") -> "x64"
      true -> "x86"
    end
  end

  defp get_retry_attempt do
    Process.get(:__auth2api_ex_retry_attempt, 0)
  end

  defp get_stainless_os do
    case :os.type() do
      {:unix, :darwin} -> "MacOS"
      {:win32, _} -> "Windows"
      {:unix, :freebsd} -> "FreeBSD"
      _ -> "Linux"
    end
  end

  # ── Header building ──

  @doc """
  Public test hook — exposes header construction so tests can verify
  the wire-level casing/ordering parity with the Node.js reference.
  Do NOT use from app code; call `call_anthropic_messages/1` instead.
  """
  @spec build_headers_for_test(
          String.t(),
          boolean(),
          integer(),
          String.t(),
          map(),
          String.t() | nil,
          boolean(),
          map() | nil
        ) :: [{String.t(), String.t()}]
  def build_headers_for_test(
        token,
        stream,
        timeout_ms,
        model,
        cloaking,
        api_key_hash,
        structured,
        extra_headers
      ) do
    build_headers(
      token,
      stream,
      timeout_ms,
      model,
      cloaking,
      api_key_hash,
      structured,
      extra_headers
    )
  end

  defp build_headers(
         token,
         stream,
         timeout_ms,
         model,
         cloaking,
         api_key_hash,
         structured,
         extra_headers
       ) do
    cli_version = cloaking[:cli_version] || @default_cli_version
    entrypoint = cloaking[:entrypoint] || @default_entrypoint
    session_id = get_session_id(api_key_hash || "default")

    # Header casing mirrors mitmproxy capture of real Claude Code CLI:
    # - anthropic-*, x-app, x-client-request-id: lowercase
    # - Everything else: Title-Case
    # Use a keyword list to preserve insertion order (matches Stainless SDK).
    base = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{token}"},
      {"User-Agent", "claude-cli/#{cli_version} (external, #{entrypoint})"},
      {"X-Claude-Code-Session-Id", session_id},
      {"X-Stainless-Lang", "js"},
      {"X-Stainless-Package-Version", "0.74.0"},
      {"X-Stainless-Runtime", "node"},
      {"X-Stainless-Runtime-Version", "v22.13.0"},
      {"X-Stainless-Arch", get_stainless_arch()},
      {"X-Stainless-Os", get_stainless_os()},
      {"X-Stainless-Timeout", to_string(max(1, ceil(timeout_ms / 1000)))},
      {"X-Stainless-Retry-Count", to_string(get_retry_attempt())},
      {"Accept", if(stream, do: "text/event-stream", else: "application/json")},
      {"anthropic-dangerous-direct-browser-access", "true"},
      {"anthropic-version", "2023-06-01"},
      {"x-app", "cli"},
      {"x-client-request-id", UUID.uuid4()}
    ]

    # Override with extra headers (e.g. anthropic-* from claude-cli clients).
    # Keys are matched case-insensitively to avoid duplicates when both
    # base and extras carry the same logical header.
    base = merge_headers(base, extra_headers || %{})

    # anthropic-beta: if a passthrough value was supplied, ensure
    # `oauth-2025-04-20` is present without duplicating it.
    case find_header(base, "anthropic-beta") do
      nil ->
        base ++ [{"anthropic-beta", build_beta_header(model, !!structured)}]

      existing ->
        replace_header(base, "anthropic-beta", ensure_oauth_beta(existing))
    end
  end

  defp ensure_oauth_beta(existing) do
    betas =
      existing
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    betas =
      if "oauth-2025-04-20" in betas do
        betas
      else
        ["oauth-2025-04-20" | betas]
      end

    Enum.uniq(betas) |> Enum.join(",")
  end

  defp merge_headers(base, extras) do
    extras_list =
      case extras do
        %{} = m -> Map.to_list(m)
        list when is_list(list) -> list
      end

    Enum.reduce(extras_list, base, fn {k, v}, acc ->
      if find_header(acc, k) do
        replace_header(acc, k, v)
      else
        acc ++ [{k, v}]
      end
    end)
  end

  defp find_header(headers, name) do
    needle = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == needle, do: v, else: nil
    end)
  end

  defp replace_header(headers, name, new_value) do
    needle = String.downcase(name)

    Enum.map(headers, fn {k, v} ->
      if String.downcase(k) == needle, do: {k, new_value}, else: {k, v}
    end)
  end

  # ── Passthrough headers for Claude Code CLI clients ──

  defp extract_passthrough_headers(conn) do
    user_agent = List.first(Plug.Conn.get_req_header(conn, "user-agent")) || ""

    if String.downcase(user_agent) |> String.starts_with?("claude-cli") do
      passthrough =
        conn.req_headers
        |> Enum.filter(fn {key, _} -> String.starts_with?(key, "anthropic") end)
        |> Enum.into(%{})

      # Also pass session ID
      passthrough =
        case Plug.Conn.get_req_header(conn, "x-claude-code-session-id") do
          [id | _] -> Map.put(passthrough, "x-claude-code-session-id", id)
          _ -> passthrough
        end

      passthrough
    else
      nil
    end
  end

  # ── Public API ──

  @doc """
  Call the Anthropic Messages API.
  """
  @spec call_anthropic_messages(keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def call_anthropic_messages(opts) do
    body = Keyword.get(opts, :body)
    conn = Keyword.fetch!(opts, :conn)
    account = Keyword.fetch!(opts, :account)
    config = Keyword.fetch!(opts, :config)
    structured = Keyword.get(opts, :structured, false)

    url = "#{@base_url}/v1/messages?beta=true"
    stream = !!(body && body["stream"])
    model = (body && body["model"]) || "claude-sonnet-4-6"
    api_key_hash = Common.hash_api_key(Common.extract_api_key(conn))

    timeout_ms =
      if stream do
        config.timeouts.stream_messages_ms
      else
        config.timeouts.messages_ms
      end

    headers =
      build_headers(
        account.token.access_token,
        stream,
        timeout_ms,
        model,
        config.cloaking,
        api_key_hash,
        structured,
        extract_passthrough_headers(conn)
      )

    req_opts = [
      headers: headers,
      body: Jason.encode!(body),
      receive_timeout: timeout_ms,
      connect_options: [timeout: 30_000, protocols: [:http2]]
    ]

    # For streaming requests, use async mode so chunks arrive incrementally
    req_opts = if stream, do: Keyword.put(req_opts, :into, :self), else: req_opts

    # Test hook: Process dictionary plug overrides real HTTP for e2e tests
    req_opts = maybe_put_test_plug(req_opts, conn)

    Req.post(url, req_opts)
  end

  @doc """
  Call the Anthropic Count Tokens API.
  """
  @spec call_anthropic_count_tokens(keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def call_anthropic_count_tokens(opts) do
    conn = Keyword.fetch!(opts, :conn)
    account = Keyword.fetch!(opts, :account)
    config = Keyword.fetch!(opts, :config)
    body = Keyword.get(opts, :body, %{})

    url = "#{@base_url}/v1/messages/count_tokens?beta=true"
    model = body["model"] || "claude-sonnet-4-6"
    api_key_hash = Common.hash_api_key(Common.extract_api_key(conn))
    timeout_ms = config.timeouts.count_tokens_ms

    headers =
      build_headers(
        account.token.access_token,
        false,
        timeout_ms,
        model,
        config.cloaking,
        api_key_hash,
        false,
        extract_passthrough_headers(conn)
      )

    Req.post(url,
      headers: headers,
      body: Jason.encode!(body),
      receive_timeout: timeout_ms,
      connect_options: [timeout: 30_000, protocols: [:http2]]
    )
  end

  # ── Test hook ──

  defp maybe_put_test_plug(req_opts, conn) do
    case conn.assigns[:test_plug] || Process.get(:__auth2api_ex_anthropic_plug__) || Application.get_env(:auth2api_ex, :test_plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end
end
