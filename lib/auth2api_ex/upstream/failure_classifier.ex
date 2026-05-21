defmodule Auth2ApiEx.Upstream.FailureClassifier do
  @moduledoc """
  Classify upstream HTTP responses into failure kinds for account cooldown decisions.

  Uses both HTTP status codes and response body content to distinguish
  quota_exhausted from rate_limit and auth from forbidden.
  """

  @type failure_kind :: :rate_limit | :quota_exhausted | :auth | :forbidden | :server

  @doc """
  Classify an HTTP status + response body (map or raw binary, or nil) into a
  failure_kind, or return :ok for non-failure responses.

  ## Classification rules

  | HTTP status | Response body feature | Returns |
  |---|---|---|
  | 200–299 | — | `:ok` |
  | 401 | — | `:auth` |
  | 403 | body contains "quota" or "usage limit" | `:quota_exhausted` |
  | 403 | other | `:forbidden` |
  | 429 | body contains "quota" or "limit_exceeded" | `:quota_exhausted` |
  | 429 | other | `:rate_limit` |
  | 408 / 5xx | — | `:server` |
  | other | — | `:ok` (client errors, do not cooldown) |
  """
  @spec classify(integer(), map() | binary() | nil) :: failure_kind() | :ok
  def classify(status, body \\ nil)

  def classify(status, body), do: classify(status, [], body)

  @doc """
  Classify an HTTP status using both response headers and response body.

  Headers catch provider-specific quota signals, while the body catches
  generic error payloads such as `quota exceeded` or `limit_exceeded`.
  """
  @spec classify(integer(), [{String.t(), String.t()}], map() | binary() | nil) ::
          failure_kind() | :ok
  def classify(status, headers, body)

  def classify(status, _headers, _body) when status >= 200 and status < 300, do: :ok

  def classify(401, _headers, _body), do: :auth

  def classify(403, headers, body) do
    if quota_exhausted?(headers, body), do: :quota_exhausted, else: :forbidden
  end

  def classify(429, headers, body) do
    if quota_exhausted?(headers, body), do: :quota_exhausted, else: :rate_limit
  end

  def classify(status, _headers, _body) when status == 408 or status >= 500, do: :server

  def classify(_status, _headers, _body), do: :ok

  # ── Private helpers ──

  defp quota_exhausted?(headers, body), do: quota_headers?(headers) or quota_body?(body)

  defp quota_headers?(headers) when is_list(headers) do
    header_map = Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    anthropic_exhausted =
      Map.get(header_map, "anthropic-ratelimit-unified-5h-surpassed-threshold") == "true" or
        Map.get(header_map, "anthropic-ratelimit-unified-7d-surpassed-threshold") == "true"

    codex_exhausted =
      header_map
      |> Map.take(["x-codex-primary-used-percent", "x-codex-secondary-used-percent"])
      |> Enum.any?(fn {_name, value} ->
        case Float.parse(value) do
          {pct, _} -> pct >= 100.0
          :error -> false
        end
      end)

    anthropic_exhausted or codex_exhausted
  end

  defp quota_headers?(_headers), do: false

  defp quota_body?(nil), do: false

  defp quota_body?(body) when is_map(body) do
    body_str = Jason.encode!(body) |> String.downcase()

    String.contains?(body_str, "quota") or String.contains?(body_str, "usage limit") or
      String.contains?(body_str, "limit_exceeded")
  end

  defp quota_body?(body) when is_binary(body) do
    lower = String.downcase(body)

    String.contains?(lower, "quota") or String.contains?(lower, "usage limit") or
      String.contains?(lower, "limit_exceeded")
  end
end
