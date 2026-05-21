defmodule Auth2ApiEx.SessionKeyTest do
  use ExUnit.Case, async: true

  alias Auth2ApiEx.Utils.SessionKey

  describe "from_request/2" do
    test "returns nil when no session fields present" do
      conn = conn_with_auth("Bearer sk-test")
      assert SessionKey.from_request(conn, %{}) == nil
    end

    test "same session + same API key → same key" do
      c1 = conn_with_auth("Bearer sk-abc")
      c2 = conn_with_auth("Bearer sk-abc")
      body = %{"prompt_cache_key" => "pc-123"}
      assert SessionKey.from_request(c1, body) == SessionKey.from_request(c2, body)
    end

    test "same session + different API keys → different internal sticky keys" do
      c1 = conn_with_auth("Bearer sk-aaa")
      c2 = conn_with_auth("Bearer sk-bbb")
      body = %{"prompt_cache_key" => "pc-shared"}
      refute SessionKey.from_request(c1, body) == SessionKey.from_request(c2, body)
    end

    test "extracts from session_id header (highest priority)" do
      conn =
        conn_with_auth("Bearer sk-test")
        |> Plug.Conn.put_req_header("session_id", "sess-123")

      body = %{"prompt_cache_key" => "pc-456"}
      result = SessionKey.from_request(conn, body)
      assert result != nil
      assert String.starts_with?(result, "s:")
    end

    test "session_id header wins over conversation_id" do
      conn =
        conn_with_auth("Bearer sk-test")
        |> Plug.Conn.put_req_header("session_id", "sess-first")
        |> Plug.Conn.put_req_header("conversation_id", "conv-second")

      conn_sess =
        conn_with_auth("Bearer sk-test")
        |> Plug.Conn.put_req_header("session_id", "sess-first")

      assert SessionKey.from_request(conn, %{}) ==
               SessionKey.from_request(conn_sess, %{})
    end

    test "conversation_id wins over body prompt_cache_key" do
      conn =
        conn_with_auth("Bearer sk-test")
        |> Plug.Conn.put_req_header("conversation_id", "conv-first")

      body = %{"prompt_cache_key" => "pc-ignored"}

      conn_conv =
        conn_with_auth("Bearer sk-test")
        |> Plug.Conn.put_req_header("conversation_id", "conv-first")

      assert SessionKey.from_request(conn, body) ==
               SessionKey.from_request(conn_conv, %{})
    end

    test "ignores empty header values" do
      conn =
        conn_with_auth("Bearer sk-test")
        |> Plug.Conn.put_req_header("session_id", "")

      body = %{"prompt_cache_key" => "pc-valid"}
      result = SessionKey.from_request(conn, body)
      assert result != nil
    end

    test "returns nil for empty prompt_cache_key in body" do
      conn = conn_with_auth("Bearer sk-test")
      body = %{"prompt_cache_key" => ""}
      assert SessionKey.from_request(conn, body) == nil
    end
  end

  describe "from_request_or_api_key/2" do
    test "falls back to API key hash when no session fields" do
      conn = conn_with_auth("Bearer sk-apikey")
      result = SessionKey.from_request_or_api_key(conn, %{})
      assert result != nil
      assert String.starts_with?(result, "k:")
    end

    test "prefers session_id over API key" do
      conn =
        conn_with_auth("Bearer sk-apikey")
        |> Plug.Conn.put_req_header("session_id", "sess-1")

      result = SessionKey.from_request_or_api_key(conn, %{})
      assert String.starts_with?(result, "s:")
    end

    test "same request → same composite key" do
      c1 = conn_with_auth("Bearer sk-x")
      c2 = conn_with_auth("Bearer sk-x")
      body = %{"prompt_cache_key" => "pc"}

      assert SessionKey.from_request_or_api_key(c1, body) ==
               SessionKey.from_request_or_api_key(c2, body)
    end

    test "fallback key is namespaced under k: prefix" do
      c1 = conn_with_auth("Bearer sk-x")
      c2 = conn_with_auth("Bearer sk-y")
      k1 = SessionKey.from_request_or_api_key(c1, %{})
      k2 = SessionKey.from_request_or_api_key(c2, %{})
      assert String.starts_with?(k1, "k:")
      assert String.starts_with?(k2, "k:")
      refute k1 == k2
    end
  end

  describe "upstream_prompt_cache_key/1" do
    test "returns trimmed short prompt_cache_key unchanged for personal use" do
      assert SessionKey.upstream_prompt_cache_key("  cache-key  ") == "cache-key"
    end

    test "compresses long prompt_cache_key to a stable value within upstream limit" do
      raw = String.duplicate("x", 100)
      h1 = SessionKey.upstream_prompt_cache_key(raw)
      h2 = SessionKey.upstream_prompt_cache_key(raw)

      assert h1 == h2
      assert String.starts_with?(h1, "a2a:")
      assert String.length(h1) <= 64
      refute h1 == raw
    end

    test "returns empty string for empty prompt_cache_key" do
      assert SessionKey.upstream_prompt_cache_key("") == ""
      assert SessionKey.upstream_prompt_cache_key("  ") == ""
    end
  end

  describe "prompt_cache_key/1" do
    test "extracts trimmed value from body" do
      assert SessionKey.prompt_cache_key(%{"prompt_cache_key" => "  abc  "}) == "abc"
    end

    test "returns nil when absent or empty" do
      assert SessionKey.prompt_cache_key(%{}) == nil
      assert SessionKey.prompt_cache_key(%{"prompt_cache_key" => ""}) == nil
    end
  end

  describe "api_key_hash/1" do
    test "returns consistent hash for same key" do
      c1 = conn_with_auth("Bearer sk-test")
      c2 = conn_with_auth("Bearer sk-test")
      assert SessionKey.api_key_hash(c1) == SessionKey.api_key_hash(c2)
    end

    test "returns different hash for different keys" do
      c1 = conn_with_auth("Bearer sk-aaa")
      c2 = conn_with_auth("Bearer sk-bbb")
      refute SessionKey.api_key_hash(c1) == SessionKey.api_key_hash(c2)
    end
  end

  defp conn_with_auth(auth) do
    Plug.Test.conn(:post, "/v1/responses", "")
    |> Plug.Conn.put_req_header("authorization", auth)
  end
end
