defmodule Auth2ApiEx.Utils.HTTP do
  @moduledoc """
  HTTP proxy utilities: retry logic, failure classification,
  and rate-limit utilization parsing for Anthropic and Codex.

  Error response construction is delegated to `Auth2ApiEx.Utils.HTTP.ErrorResponse`.
  """

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Config
  alias Auth2ApiEx.Upstream.FailureClassifier

  import Auth2ApiEx.PlugHelpers, only: [send_json: 3]

  @max_retries 3
  @retryable_statuses MapSet.new([429, 500, 502, 503, 504])

  @type failure_kind :: :rate_limit | :quota_exhausted | :auth | :forbidden | :server | :network

  # ── UtilizationInfo ──
  # Unified normalized structure for both Anthropic and Codex rate-limit data.

  defmodule UtilizationInfo do
    @moduledoc """
    Normalized rate-limit utilization snapshot.
    Both Anthropic (anthropic-ratelimit-* headers) and Codex (x-codex-* headers)
    parse into this common structure.
    """
    defstruct utilization_5h: nil,
              reset_5h: nil,
              reset_5h_seconds: nil,
              window_5h_minutes: nil,
              utilization_7d: nil,
              reset_7d: nil,
              reset_7d_seconds: nil,
              window_7d_minutes: nil,
              updated_at: nil

    @type t :: %__MODULE__{
            utilization_5h: float() | nil,
            reset_5h: String.t() | nil,
            reset_5h_seconds: integer() | nil,
            window_5h_minutes: integer() | nil,
            utilization_7d: float() | nil,
            reset_7d: String.t() | nil,
            reset_7d_seconds: integer() | nil,
            window_7d_minutes: integer() | nil,
            updated_at: String.t() | nil
          }
  end

  # ── OpenAI-compatible error body adapter (delegated) ──

  defdelegate openai_error_body(status, body), to: Auth2ApiEx.Utils.HTTP.ErrorResponse

  # ── Failure classification ──

  @doc """
  Classify an HTTP status code into a failure kind.
  """
  @spec classify_failure(integer()) :: failure_kind()
  def classify_failure(status) do
    case FailureClassifier.classify(status) do
      :ok -> :server
      kind -> kind
    end
  end

  @doc """
  Classify an HTTP status code + response headers into a failure kind.
  Headers are examined to distinguish quota_exhausted from rate_limit on 429.

  Anthropic: surpassed-threshold header
  Codex: x-codex-*-used-percent >= 100
  """
  @spec classify_failure(integer(), [{String.t(), String.t()}]) :: failure_kind()
  def classify_failure(status, headers) do
    classify_failure(status, headers, nil)
  end

  @doc """
  Classify an HTTP status + response headers + response body into a failure kind.
  """
  @spec classify_failure(integer(), [{String.t(), String.t()}], map() | binary() | nil) ::
          failure_kind()
  def classify_failure(status, headers, body) do
    case FailureClassifier.classify(status, headers, body) do
      :ok -> :server
      kind -> kind
    end
  end

  # ── Utilization parsers ──

  @doc """
  Parse Anthropic rate-limit response headers into UtilizationInfo.
  """
  @spec parse_anthropic_utilization([{String.t(), String.t()}]) :: UtilizationInfo.t()
  def parse_anthropic_utilization(headers) do
    %UtilizationInfo{
      utilization_5h: get_header_float(headers, "anthropic-ratelimit-unified-5h-utilization"),
      utilization_7d: get_header_float(headers, "anthropic-ratelimit-unified-7d-utilization"),
      reset_5h: get_header(headers, "anthropic-ratelimit-unified-5h-reset"),
      reset_7d: get_header(headers, "anthropic-ratelimit-unified-7d-reset"),
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Parse Codex rate-limit response headers into UtilizationInfo.
  Implements Normalize() logic from sub2api:
  - Both windows present: smaller window_minutes → 5h, larger → 7d
  - Single window: ≤ 360 min → 5h, > 360 min → 7d
  """
  @spec parse_codex_utilization([{String.t(), String.t()}]) :: UtilizationInfo.t()
  def parse_codex_utilization(headers) do
    pri_pct = get_header_float(headers, "x-codex-primary-used-percent")
    pri_reset = get_header_int(headers, "x-codex-primary-reset-after-seconds")
    pri_window = get_header_int(headers, "x-codex-primary-window-minutes")
    sec_pct = get_header_float(headers, "x-codex-secondary-used-percent")
    sec_reset = get_header_int(headers, "x-codex-secondary-reset-after-seconds")
    sec_window = get_header_int(headers, "x-codex-secondary-window-minutes")

    {u5h, r5h_sec, w5h, u7d, r7d_sec, w7d} =
      normalize_codex(pri_pct, pri_reset, pri_window, sec_pct, sec_reset, sec_window)

    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    %UtilizationInfo{
      utilization_5h: u5h,
      reset_5h_seconds: r5h_sec,
      reset_5h: if(r5h_sec, do: compute_reset_iso(r5h_sec), else: nil),
      window_5h_minutes: w5h,
      utilization_7d: u7d,
      reset_7d_seconds: r7d_sec,
      reset_7d: if(r7d_sec, do: compute_reset_iso(r7d_sec), else: nil),
      window_7d_minutes: w7d,
      updated_at: now_iso
    }
  end

  # ── Public ──

  def account_unavailable(conn, result, opts \\ []) do
    Auth2ApiEx.Utils.HTTP.ErrorResponse.account_unavailable(conn, result, opts)
  end

  @doc """
  Execute a proxy request with retry logic.
  Options:
    - :upstream — required, fn to call upstream API
    - :success — required, fn to handle successful response
    - :max_retries — maximum retry attempts (default 3)
    - :session_key — sticky-session key (downstream API key hash)
    - :model — model name for audit logging
    - :error_adapter — optional `(status, body) -> map` to translate the
      upstream error body shape (e.g. Anthropic/Codex → OpenAI). Mirrors
      the Node.js `errorAdapter` option.
  """
  @spec proxy_with_retry(String.t(), Plug.Conn.t(), Config.t(), module(), keyword()) ::
          Plug.Conn.t()
  def proxy_with_retry(tag, conn, config, manager, opts) do
    upstream_fn = Keyword.fetch!(opts, :upstream)
    success_fn = Keyword.fetch!(opts, :success)
    max_retries = Keyword.get(opts, :max_retries, @max_retries)
    session_key = Keyword.get(opts, :session_key)
    model = Keyword.get(opts, :model)
    error_adapter = Keyword.get(opts, :error_adapter)

    state = %{
      tag: tag,
      config: config,
      manager: manager,
      upstream_fn: upstream_fn,
      success_fn: success_fn,
      max_retries: max_retries,
      session_key: session_key,
      model: model,
      error_adapter: error_adapter
    }

    do_proxy(conn, state, 0, nil, "", nil, MapSet.new())
  end

  defp do_proxy(conn, state, attempt, last_status, last_err_body, last_retry_after, _refreshed)
       when attempt >= state.max_retries do
    # All retries exhausted — return last upstream status and body
    # (matches Node.js behavior; forwards Retry-After when present).
    if last_status && last_status > 0 do
      Auth2ApiEx.Utils.HTTP.ErrorResponse.return_error_response(
        conn,
        last_status,
        last_err_body || "",
        last_retry_after,
        state.error_adapter
      )
    else
      send_json(conn, 503, %{error: %{message: "Upstream request failed"}})
    end
  end

  defp do_proxy(
         conn,
         state,
         attempt,
         _last_status,
         _last_err_body,
         _last_retry_after,
         refreshed_accounts
       ) do
    %{
      tag: tag,
      config: config,
      manager: manager,
      upstream_fn: upstream_fn,
      success_fn: success_fn,
      max_retries: max_retries,
      session_key: session_key,
      model: model,
      error_adapter: error_adapter
    } = state

    result = Manager.get_next_account(manager, session_key)

    require Logger

    case result do
      %{account: nil} ->
        Logger.warning(
          "[#{tag}] no available account failure_kind=#{inspect(result.failure_kind)} retry_after_ms=#{result.retry_after_ms}"
        )

        account_unavailable(conn, result)

      %{account: account} ->
        Manager.record_attempt(manager, account.token.email)
        start_time = System.monotonic_time(:millisecond)

        # Stash retry attempt so upstream header builders can set X-Stainless-Retry-Count
        Process.put(:__auth2api_ex_retry_attempt, attempt)

        case upstream_fn.(account) do
          {:ok, %Req.Response{status: status} = upstream} when status >= 200 and status < 300 ->
            duration_ms = System.monotonic_time(:millisecond) - start_time

            record_audit(
              conn,
              tag,
              model,
              account.token.email,
              status,
              duration_ms,
              nil,
              session_key
            )

            if session_key && result[:sticky_miss] do
              Manager.bind_session(manager, session_key, account.token.email)
            end

            try do
              success_fn.(upstream, account)
            rescue
              e ->
                if response_started?(conn) do
                  if Config.debug_level?(config.debug, :errors) do
                    require Logger

                    Logger.error(
                      "#{tag} success handler failed after response started: #{Exception.message(e)}"
                    )
                  end

                  conn
                else
                  reraise e, __STACKTRACE__
                end
            end

          # 401 — attempt token refresh, retry without consuming attempt count
          {:ok, %Req.Response{status: 401} = upstream} ->
            err_body = get_response_body(upstream)
            retry_after = get_retry_after(upstream.headers)
            duration_ms = System.monotonic_time(:millisecond) - start_time

            record_audit(
              conn,
              tag,
              model,
              account.token.email,
              401,
              duration_ms,
              err_body,
              session_key
            )

            log_failure(config, tag, attempt, 401, err_body)

            if session_key, do: Manager.clear_session(manager, session_key)

            already_refreshed = MapSet.member?(refreshed_accounts, account.token.email)

            if !already_refreshed && Manager.refresh_account(manager, account.token.email) do
              Process.sleep((attempt + 1) * 1000)

              do_proxy(
                conn,
                state,
                attempt,
                401,
                err_body,
                retry_after,
                MapSet.put(refreshed_accounts, account.token.email)
              )
            else
              Manager.record_failure(manager, account.token.email, :auth, "401 Unauthorized")

              Auth2ApiEx.Utils.HTTP.ErrorResponse.return_error_response(
                conn,
                401,
                err_body,
                retry_after,
                error_adapter
              )
            end

          # Other error statuses — classify, record, maybe retry
          {:ok, %Req.Response{status: status, headers: headers} = upstream} ->
            err_body = get_response_body(upstream)
            retry_after = get_retry_after(headers)
            duration_ms = System.monotonic_time(:millisecond) - start_time

            Logger.error(
              "[#{tag}] upstream #{status} model=#{model} duration=#{duration_ms}ms attempt=#{attempt + 1} body=#{String.slice(err_body, 0, 200)}"
            )

            record_audit(
              conn,
              tag,
              model,
              account.token.email,
              status,
              duration_ms,
              err_body,
              session_key
            )

            log_failure(config, tag, attempt, status, err_body)

            # Mirror Node.js: only cooldown the account for server-side failures
            # (403, 429, 5xx). Client errors (400, 404, 422, …) mean the
            # account is healthy — the request body is bad. Cooling down here
            # would unfairly penalize a working account for a user typo.
            if status == 403 or status == 429 or status >= 500 do
              Manager.record_failure(
                manager,
                account.token.email,
                classify_failure(status, headers, err_body),
                "HTTP #{status}"
              )
            end

            if MapSet.member?(@retryable_statuses, status) and attempt < max_retries - 1 do
              Process.sleep((attempt + 1) * 1000)

              do_proxy(
                conn,
                state,
                attempt + 1,
                status,
                err_body,
                retry_after,
                refreshed_accounts
              )
            else
              Auth2ApiEx.Utils.HTTP.ErrorResponse.return_error_response(
                conn,
                status,
                err_body,
                retry_after,
                error_adapter
              )
            end

          {:error, exception} ->
            cause = format_exception_cause(exception)
            duration_ms = System.monotonic_time(:millisecond) - start_time

            Logger.error(
              "[#{tag}] network error model=#{model} attempt=#{attempt + 1} duration=#{duration_ms}ms cause=#{cause}"
            )

            record_audit(
              conn,
              tag,
              model,
              account.token.email,
              500,
              duration_ms,
              cause,
              session_key
            )

            Manager.record_failure(manager, account.token.email, :network, cause)

            if Config.debug_level?(config.debug, :errors) do
              require Logger
              Logger.error("#{tag} attempt #{attempt + 1} network failure: #{cause}")
            end

            if attempt < max_retries - 1 do
              Process.sleep((attempt + 1) * 1000)
              do_proxy(conn, state, attempt + 1, 500, "", nil, refreshed_accounts)
            else
              send_json(conn, 502, %{error: %{message: "Upstream network error: #{cause}"}})
            end
        end
    end
  end

  # Surface Req's underlying transport error (Mint.TransportError, etc.) when
  # it's wrapped — `Exception.message/1` alone often hides the root cause.
  defp format_exception_cause(%{__exception__: true} = exc) do
    base = Exception.message(exc) || inspect(exc)

    case Map.get(exc, :reason) do
      nil -> base
      reason when is_atom(reason) -> "#{base} (#{reason})"
      reason -> "#{base} (#{inspect(reason)})"
    end
  end

  defp format_exception_cause(other), do: inspect(other)

  defp response_started?(%Plug.Conn{state: state}) when state in [:set, :unset], do: false
  defp response_started?(%Plug.Conn{}), do: true

  defp get_retry_after(headers) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == "retry-after", do: v, else: nil
    end)
  end

  defp get_retry_after(_), do: nil

  defp log_failure(config, tag, attempt, status, err_body) do
    if Config.debug_level?(config.debug, :errors) do
      require Logger
      Logger.error("#{tag} attempt #{attempt + 1} failed (#{status}): #{err_body}")
    end
  end

  defp record_audit(conn, tag, model, email, status, duration_ms, error, session_key) do
    Auth2ApiEx.AuditLog.record(%{
      method: conn.method,
      path: conn.request_path,
      type: tag,
      model: model,
      provider: derive_provider(tag),
      account_email: email,
      status: status,
      duration_ms: duration_ms,
      error: if(error, do: String.slice(to_string(error), 0, 200)),
      input_tokens: 0,
      output_tokens: 0,
      stream: false,
      session_key: if(session_key, do: String.slice(session_key, 0, 6))
    })
  end

  defp derive_provider("CodexResponses"), do: "codex"
  defp derive_provider("CodexCountTokens"), do: "codex"
  defp derive_provider(_), do: "anthropic"

  defp get_response_body(%Req.Response{body: %Req.Response.Async{}}), do: ""
  defp get_response_body(%Req.Response{body: body}) when is_binary(body), do: body
  defp get_response_body(%Req.Response{body: body}) when is_map(body), do: Jason.encode!(body)
  defp get_response_body(_), do: ""

  # ── Header parsing helpers ──

  defp normalize_codex(nil, nil, nil, nil, nil, nil), do: {nil, nil, nil, nil, nil, nil}

  defp normalize_codex(pri_pct, pri_reset, pri_window, nil, nil, nil) do
    if pri_window && pri_window <= 360 do
      {pri_pct, pri_reset, pri_window, nil, nil, nil}
    else
      {nil, nil, nil, pri_pct, pri_reset, pri_window}
    end
  end

  defp normalize_codex(nil, nil, nil, sec_pct, sec_reset, sec_window) do
    if sec_window && sec_window > 360 do
      {nil, nil, nil, sec_pct, sec_reset, sec_window}
    else
      {sec_pct, sec_reset, sec_window, nil, nil, nil}
    end
  end

  defp normalize_codex(pri_pct, pri_reset, pri_window, sec_pct, sec_reset, sec_window) do
    cond do
      pri_window && sec_window && pri_window < sec_window ->
        # primary is smaller -> primary=5h, secondary=7d
        {pri_pct, pri_reset, pri_window, sec_pct, sec_reset, sec_window}

      pri_window && sec_window ->
        # secondary is smaller or equal -> secondary=5h, primary=7d
        {sec_pct, sec_reset, sec_window, pri_pct, pri_reset, pri_window}

      pri_window ->
        if pri_window <= 360 do
          {pri_pct, pri_reset, pri_window, sec_pct, sec_reset, sec_window}
        else
          {sec_pct, sec_reset, sec_window, pri_pct, pri_reset, pri_window}
        end

      sec_window ->
        if sec_window <= 360 do
          {sec_pct, sec_reset, sec_window, pri_pct, pri_reset, pri_window}
        else
          {pri_pct, pri_reset, pri_window, sec_pct, sec_reset, sec_window}
        end

      true ->
        # Legacy assumption from sub2api: primary=7d, secondary=5h.
        {sec_pct, sec_reset, sec_window, pri_pct, pri_reset, pri_window}
    end
  end

  defp compute_reset_iso(seconds) when is_number(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp get_header(headers, name) do
    header_map = Map.new(headers, fn {k, v} -> {String.downcase(k), v} end)
    Map.get(header_map, String.downcase(name))
  end

  defp get_header_float(headers, name) do
    case get_header(headers, name) do
      nil -> nil
      val -> parse_float(val)
    end
  end

  defp get_header_int(headers, name) do
    case get_header(headers, name) do
      nil -> nil
      val -> parse_int(val)
    end
  end

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_float(val) when is_integer(val), do: val * 1.0
  defp parse_float(val) when is_float(val), do: val
  defp parse_float([val | _]), do: parse_float(val)
  defp parse_float(_), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_float(val), do: trunc(val)
  defp parse_int([val | _]), do: parse_int(val)
  defp parse_int(_), do: nil
end
