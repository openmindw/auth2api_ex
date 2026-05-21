defmodule Auth2ApiEx.PromptCacheKeyIntegrationTest do
  @moduledoc """
  Integration tests for prompt_cache_key-based sticky selection and
  upstream session header injection.
  """

  use ExUnit.Case, async: false

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Auth.TokenData
  alias Auth2ApiEx.Utils.SessionKey
  alias Auth2ApiEx.Upstream.CodexAPI

  @test_config %{
    debug: "off",
    cloaking: %{codex: %{"originator" => "codex_cli_rs", "cli-version" => "0.125.0"}},
    timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
  }

  defp make_token(email) do
    %TokenData{
      access_token: "tok-#{email}",
      refresh_token: "rt",
      email: email,
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "uuid-#{email}",
      provider: "anthropic"
    }
  end

  defp start_multi_account_manager do
    auth_dir = Path.join(System.tmp_dir!(), "pck-#{System.unique_integer([:positive])}")
    File.mkdir_p!(auth_dir)
    name = String.to_atom("pck_mgr_#{System.unique_integer([:positive])}")

    {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)

    Manager.add_account(name, make_token("a@test.com"))
    Manager.add_account(name, make_token("b@test.com"))
    Manager.add_account(name, make_token("c@test.com"))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(auth_dir)
    end)

    {name, pid}
  end

  defp build_conn(body_map, headers) do
    json = Jason.encode!(body_map)

    conn =
      Plug.Test.conn(:post, "/v1/responses", json)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    {conn, body_map}
  end

  describe "sticky selection with prompt_cache_key" do
    test "same prompt_cache_key + same API key → same account" do
      {mgr, _pid} = start_multi_account_manager()

      {conn1, body1} =
        build_conn(
          %{"prompt_cache_key" => "cache-key-a"},
          [{"authorization", "Bearer sk-test"}]
        )

      {conn2, body2} =
        build_conn(
          %{"prompt_cache_key" => "cache-key-a"},
          [{"authorization", "Bearer sk-test"}]
        )

      key1 = SessionKey.from_request_or_api_key(conn1, body1)
      key2 = SessionKey.from_request_or_api_key(conn2, body2)

      assert key1 == key2
      assert String.starts_with?(key1, "s:")

      r1 = Manager.get_next_account(mgr, key1)
      assert r1.account != nil

      Manager.bind_session(mgr, key1, r1.account.token.email)
      r2 = Manager.get_next_account(mgr, key1)
      assert r2.account.token.email == r1.account.token.email
    end

    test "same prompt_cache_key + different API keys → different internal sticky keys" do
      {_mgr, _pid} = start_multi_account_manager()

      {conn_a, body_a} =
        build_conn(
          %{"prompt_cache_key" => "pc-shared"},
          [{"authorization", "Bearer sk-aaa"}]
        )

      {conn_b, body_b} =
        build_conn(
          %{"prompt_cache_key" => "pc-shared"},
          [{"authorization", "Bearer sk-bbb"}]
        )

      key_a = SessionKey.from_request_or_api_key(conn_a, body_a)
      key_b = SessionKey.from_request_or_api_key(conn_b, body_b)

      refute key_a == key_b
    end

    test "different prompt_cache_key can bind to different accounts" do
      {mgr, _pid} = start_multi_account_manager()

      {conn_a, body_a} =
        build_conn(
          %{"prompt_cache_key" => "cache-a"},
          [{"authorization", "Bearer sk-test"}]
        )

      {conn_b, body_b} =
        build_conn(
          %{"prompt_cache_key" => "cache-b"},
          [{"authorization", "Bearer sk-test"}]
        )

      key_a = SessionKey.from_request_or_api_key(conn_a, body_a)
      key_b = SessionKey.from_request_or_api_key(conn_b, body_b)

      assert key_a != key_b

      r_a = Manager.get_next_account(mgr, key_a)
      r_b = Manager.get_next_account(mgr, key_b)
      assert r_a.account != nil
      assert r_b.account != nil

      Manager.bind_session(mgr, key_a, r_a.account.token.email)
      Manager.bind_session(mgr, key_b, r_b.account.token.email)

      r_a2 = Manager.get_next_account(mgr, key_a)
      r_b2 = Manager.get_next_account(mgr, key_b)
      assert r_a2.account.token.email == r_a.account.token.email
      assert r_b2.account.token.email == r_b.account.token.email
    end

    test "session_id header has priority over prompt_cache_key" do
      {conn1, body1} =
        build_conn(
          %{"prompt_cache_key" => "pc-body"},
          [{"session_id", "sess-header"}, {"authorization", "Bearer sk-test"}]
        )

      {conn2, body2} =
        build_conn(
          %{},
          [{"session_id", "sess-header"}, {"authorization", "Bearer sk-test"}]
        )

      key1 = SessionKey.from_request_or_api_key(conn1, body1)
      key2 = SessionKey.from_request_or_api_key(conn2, body2)

      assert key1 == key2
    end

    test "falls back to API key when no session fields present" do
      {conn1, body1} =
        build_conn(
          %{"model" => "gpt-5"},
          [{"authorization", "Bearer sk-apikey1"}]
        )

      {conn2, body2} =
        build_conn(
          %{"model" => "gpt-5"},
          [{"authorization", "Bearer sk-apikey1"}]
        )

      key1 = SessionKey.from_request_or_api_key(conn1, body1)
      key2 = SessionKey.from_request_or_api_key(conn2, body2)

      assert key1 == key2
      assert String.starts_with?(key1, "k:")
    end
  end

  describe "CodexAPI upstream session headers" do
    setup do
      account = %{
        token: make_token("upstream@test.com"),
        chatgpt_account_id: nil
      }

      {:ok, account: account}
    end

    test "normalize_body preserves prompt_cache_key" do
      body = %{
        "model" => "gpt-5",
        "input" => [%{"type" => "message", "role" => "user", "content" => "hi"}],
        "prompt_cache_key" => "my-key"
      }

      normalized = CodexAPI.normalize_body(body)
      assert normalized["prompt_cache_key"] == "my-key"
    end

    test "upstream_prompt_cache_key preserves short keys and compresses long keys" do
      assert SessionKey.upstream_prompt_cache_key(" pc ") == "pc"

      long_key = String.duplicate("x", 100)
      compressed = SessionKey.upstream_prompt_cache_key(long_key)

      assert String.starts_with?(compressed, "a2a:")
      assert String.length(compressed) <= 64
      refute compressed == long_key
    end

    @tag :capture_log
    test "sends raw short prompt_cache_key as session headers when present", %{
      account: account
    } do
      body = %{
        "model" => "gpt-5",
        "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
        "prompt_cache_key" => "my-cache-key-123"
      }

      test_pid = self()

      stub = fn conn ->
        headers = conn.req_headers
        send(test_pid, {:captured_headers, headers})
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{id: "ok"}))
      end

      {:ok, _result} =
        CodexAPI.call_codex_responses(
          body: body,
          account: account,
          config: @test_config,
          api_key_hash: "test-api-hash",
          plug: stub,
          stream: false
        )

      assert_receive {:captured_headers, headers}, 1000
      assert find_header(headers, "session_id") == "my-cache-key-123"
      assert find_header(headers, "conversation_id") == "my-cache-key-123"
    end

    @tag :capture_log
    test "compresses long prompt_cache_key before sending upstream session headers", %{
      account: account
    } do
      long_key = String.duplicate("x", 100)

      body = %{
        "model" => "gpt-5",
        "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
        "prompt_cache_key" => long_key
      }

      test_pid = self()

      stub = fn conn ->
        send(test_pid, {:captured_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{id: "ok"}))
      end

      {:ok, _result} =
        CodexAPI.call_codex_responses(
          body: body,
          account: account,
          config: @test_config,
          plug: stub,
          stream: false
        )

      assert_receive {:captured_headers, headers}, 1000
      session_id = find_header(headers, "session_id")
      conversation_id = find_header(headers, "conversation_id")

      assert session_id == conversation_id
      assert String.starts_with?(session_id, "a2a:")
      assert String.length(session_id) <= 64
      refute session_id == long_key
    end

    @tag :capture_log
    test "does not set session_id when prompt_cache_key is absent", %{account: account} do
      body = %{
        "model" => "gpt-5",
        "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}]
      }

      test_pid = self()

      stub = fn conn ->
        headers = conn.req_headers
        send(test_pid, {:captured_headers, headers})
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{id: "ok"}))
      end

      {:ok, _result} =
        CodexAPI.call_codex_responses(
          body: body,
          account: account,
          config: @test_config,
          plug: stub,
          stream: false
        )

      assert_receive {:captured_headers, headers}, 1000
      assert find_header(headers, "session_id") == nil
      assert find_header(headers, "conversation_id") == nil
    end

    @tag :capture_log
    test "sends session headers from prompt_cache_key without requiring api_key_hash", %{
      account: account
    } do
      body = %{
        "model" => "gpt-5",
        "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
        "prompt_cache_key" => "my-key"
      }

      test_pid = self()

      stub = fn conn ->
        headers = conn.req_headers
        send(test_pid, {:captured_headers, headers})
        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{id: "ok"}))
      end

      {:ok, _result} =
        CodexAPI.call_codex_responses(
          body: body,
          account: account,
          config: @test_config,
          plug: stub,
          stream: false
        )

      assert_receive {:captured_headers, headers}, 1000
      assert find_header(headers, "session_id") == "my-key"
      assert find_header(headers, "conversation_id") == "my-key"
    end
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _ -> nil
    end)
  end
end
