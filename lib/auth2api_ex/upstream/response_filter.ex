defmodule Auth2ApiEx.Upstream.ResponseFilter do
  @moduledoc """
  Sanitize upstream response headers before forwarding to the downstream client.

  Strips headers that could leak infrastructure info, account identity, or
  trigger unwanted client-side behavior (auto-retry on rate-limit headers).
  """

  # Headers dropped by prefix (case-insensitive match)
  @drop_prefixes [
    "cf-",
    "x-amzn-",
    "x-served-by",
    "x-cache",
    "x-ratelimit-",
    "anthropic-ratelimit-",
    "openai-",
    "x-azure-"
  ]

  # Headers dropped by exact name (case-insensitive match)
  @drop_exact [
    "set-cookie",
    "server",
    "via",
    "cf-cache-status",
    "cf-ray",
    "report-to",
    "nel",
    "alt-svc",
    "x-request-id",
    "x-amz-cf-id",
    "x-content-type-options",
    "strict-transport-security"
  ]

  @doc """
  Filter upstream response headers, removing sensitive/infrastructure headers.

  Returns a new list of {name, value} tuples with only safe headers.
  """
  @spec sanitize_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def sanitize_headers(headers) when is_list(headers) do
    Enum.reject(headers, fn {name, _value} ->
      should_drop?(name)
    end)
  end

  def sanitize_headers(_), do: []

  # ── Private helpers ──

  defp should_drop?(name) do
    lower = String.downcase(name)

    # Preserve auth2api_ex-* custom headers
    if String.starts_with?(lower, "auth2api_ex-") do
      false
    else
      drop_by_prefix?(lower) or drop_by_exact?(lower)
    end
  end

  defp drop_by_prefix?(lower_name) do
    Enum.any?(@drop_prefixes, fn prefix ->
      String.starts_with?(lower_name, prefix)
    end)
  end

  defp drop_by_exact?(lower_name) do
    lower_name in @drop_exact
  end
end
