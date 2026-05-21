defmodule Auth2ApiEx.Utils.SessionKey do
  @moduledoc """
  Extract a stable session key from incoming requests to drive account
  sticky selection. Mirrors sub2api's priority chain:

    1. `session_id` header (highest priority)
    2. `conversation_id` header
    3. `prompt_cache_key` from request body (OpenAI Responses / Chat)
    4. Falls back to API-key-derived key when nothing else is present

  Internal sticky-selection keys include the API key hash so different
  downstream keys can still bind independently. Upstream prompt cache keys
  are intentionally personal-use oriented: short client keys are forwarded
  unchanged, while overlong keys are compressed to the upstream 64-character
  limit.
  """

  alias Auth2ApiEx.Utils.Common

  @doc """
  Extract a stable session key from request headers and body.

  Includes the API key hash to scope the key per downstream client.
  Returns `nil` when no session-like field is found.
  """
  @spec from_request(Plug.Conn.t(), map()) :: String.t() | nil
  def from_request(conn, body \\ %{})

  def from_request(conn, body) do
    raw =
      header(conn, "session_id") ||
        header(conn, "conversation_id") ||
        string_field(body, "prompt_cache_key")

    if raw && String.trim(raw) != "" do
      api_key_hash = api_key_hash(conn)
      "s:" <> Common.hash_api_key(api_key_hash <> ":" <> String.trim(raw))
    else
      nil
    end
  end

  @doc """
  Build a composite session key: prefer the request-derived session key,
  otherwise fall back to the API-key-derived key.

  This is the canonical entrypoint for handlers.
  """
  @spec from_request_or_api_key(Plug.Conn.t(), map()) :: String.t()
  def from_request_or_api_key(conn, body \\ %{}) do
    from_request(conn, body) || "k:" <> api_key_hash(conn)
  end

  @doc """
  Build a prompt_cache_key-compatible value for upstream session headers.

  For this personal-use proxy, preserve short client keys unchanged so cache
  behavior is predictable. If a client sends a value longer than the upstream
  64-character limit, compress it to a stable short hash.

  Returns empty string when input is empty.
  """
  @spec upstream_prompt_cache_key(String.t()) :: String.t()
  def upstream_prompt_cache_key(prompt_cache_key) when is_binary(prompt_cache_key) do
    trimmed = String.trim(prompt_cache_key)

    cond do
      trimmed == "" -> ""
      String.length(trimmed) <= 64 -> trimmed
      true -> "a2a:" <> (Common.hash_api_key(trimmed) |> String.slice(0, 56))
    end
  end

  @doc """
  Extract the raw prompt_cache_key value from a request body (unhashed).

  Returns the trimmed string or `nil`.
  """
  @spec prompt_cache_key(map()) :: String.t() | nil
  def prompt_cache_key(body) do
    case string_field(body, "prompt_cache_key") do
      nil -> nil
      "" -> nil
      val -> String.trim(val)
    end
  end

  @doc """
  Compute the stable API key hash for a connection.

  Convenience wrapper so callers don't need to alias Common.
  """
  @spec api_key_hash(Plug.Conn.t()) :: String.t()
  def api_key_hash(conn) do
    Common.hash_api_key(Common.extract_api_key(conn))
  end

  # ── Private ──

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp string_field(body, key) do
    case body do
      %{^key => value} when is_binary(value) and value != "" -> value
      %{} -> nil
      _ -> nil
    end
  end
end
