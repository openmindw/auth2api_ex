defmodule Auth2ApiEx.Utils.HTTP.ErrorResponse do
  @moduledoc """
  Error response construction for the HTTP proxy layer.
  Extracted from `Auth2ApiEx.Utils.HTTP` to separate error concerns
  from retry/streaming logic.

  Includes:
    - `openai_error_body/2` — translate upstream error shapes into OpenAI format
    - `failure_response/1` — map failure kind to {status, message}
    - `account_unavailable/3` — build 503 for no-account / all-cooled-down
    - `return_error_response/5` — send final error after retries exhausted
  """

  alias Auth2ApiEx.Accounts.Manager
  import Auth2ApiEx.PlugHelpers, only: [send_json: 3]

  # ── OpenAI-compatible error body adapter ──

  @doc """
  Translate an upstream error body (Anthropic JSON, Codex `{detail: …}`,
  or arbitrary text) into an OpenAI-shaped `{error: {message, type}}`.

  Mirrors the Node.js `openaiErrorBody` adapter — used when the inbound
  request format is OpenAI (Chat Completions / Responses) but the
  upstream is Anthropic or Codex, so clients always see a shape they can
  parse.
  """
  @spec openai_error_body(integer(), String.t()) :: %{
          error: %{message: String.t(), type: String.t()}
        }
  def openai_error_body(_status, body) do
    case Jason.decode(body || "") do
      {:ok, parsed} when is_map(parsed) ->
        message =
          get_in(parsed, ["error", "message"]) ||
            (is_binary(parsed["detail"]) && parsed["detail"]) ||
            get_in(parsed, ["error", "error", "message"]) ||
            "Upstream request failed"

        type = get_in(parsed, ["error", "type"]) || "upstream_error"

        %{error: %{message: message, type: type}}

      _ ->
        %{error: %{message: "Upstream request failed", type: "upstream_error"}}
    end
  end

  # ── account_unavailable ──

  @spec account_unavailable(Plug.Conn.t(), Manager.account_result_unavailable(), keyword()) ::
          Plug.Conn.t()
  def account_unavailable(conn, result, opts \\ []) do
    provider = Keyword.get(opts, :provider)

    case result do
      %{account: nil, failure_kind: nil} ->
        message =
          if provider,
            do: "No #{provider} accounts loaded. Run: --login --provider=#{provider}",
            else: "No available account"

        send_json(conn, 503, %{error: %{message: message}})

      %{account: nil, failure_kind: failure_kind, retry_after_ms: retry_after_ms} ->
        {status, message} = failure_response(failure_kind)

        conn =
          if retry_after_ms && retry_after_ms > 0 do
            retry_after = max(1, ceil(retry_after_ms / 1000))
            Plug.Conn.put_resp_header(conn, "retry-after", to_string(retry_after))
          else
            conn
          end

        send_json(conn, status, %{error: %{message: message}})
    end
  end

  # ── return_error_response ──

  def return_error_response(conn, status, err_body, retry_after, error_adapter) do
    conn =
      if retry_after && retry_after != "" do
        Plug.Conn.put_resp_header(conn, "retry-after", retry_after)
      else
        conn
      end

    body =
      cond do
        is_function(error_adapter, 2) ->
          try do
            error_adapter.(status, err_body || "")
          rescue
            _ -> default_error_body(err_body)
          end

        true ->
          default_error_body(err_body)
      end

    send_json(conn, status, body)
  end

  # ── failure_response ──

  @doc false
  def failure_response(kind)

  def failure_response(:rate_limit), do: {429, "Rate limited on the configured account"}
  def failure_response(:quota_exhausted), do: {429, "Account quota exhausted"}
  def failure_response(:auth), do: {503, "Configured account requires re-authentication"}
  def failure_response(:forbidden), do: {503, "Configured account is forbidden"}
  def failure_response(:server), do: {503, "Upstream server temporarily unavailable"}
  def failure_response(:network), do: {503, "Upstream network temporarily unavailable"}

  # ── Private ──

  defp default_error_body(err_body) do
    case Jason.decode(err_body || "") do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{error: %{message: "Upstream request failed"}}
    end
  end
end
