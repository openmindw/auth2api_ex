defmodule Auth2ApiEx.UpstreamParityTest do
  @moduledoc """
  Parity tests against the Node.js codex-provider-ref implementation
  for upstream forwarding: header construction, body normalization,
  error adapter, retry-after passthrough.
  """

  use ExUnit.Case, async: true

  alias Auth2ApiEx.Upstream.{CodexAPI, AnthropicAPI}
  alias Auth2ApiEx.Utils.HTTP
  alias Auth2ApiEx.Accounts.Manager.AvailableAccount
  alias Auth2ApiEx.Auth.TokenData

  # ══════════════════════════════════════════════════
  # CodexAPI.normalize_body/1
  # ══════════════════════════════════════════════════

  describe "CodexAPI.normalize_body/1" do
    test "fills in stream=true when missing" do
      body = %{"model" => "gpt-5"}
      normalized = CodexAPI.normalize_body(body)
      assert normalized["stream"] == true
    end

    test "fills in store=false when missing" do
      body = %{"model" => "gpt-5"}
      normalized = CodexAPI.normalize_body(body)
      assert normalized["store"] == false
    end

    test "fills in instructions=\"\" when missing" do
      body = %{"model" => "gpt-5"}
      normalized = CodexAPI.normalize_body(body)
      assert normalized["instructions"] == ""
    end

    test "forces stream=true even when client sends false (P0 protocol requirement)" do
      body = %{"model" => "gpt-5", "stream" => false}
      normalized = CodexAPI.normalize_body(body)
      assert normalized["stream"] == true
    end

    test "forces store=false even when client sends true (P0 protocol requirement)" do
      body = %{"model" => "gpt-5", "store" => true}
      normalized = CodexAPI.normalize_body(body)
      assert normalized["store"] == false
    end

    test "preserves explicit non-empty instructions" do
      body = %{"model" => "gpt-5", "instructions" => "be helpful"}
      normalized = CodexAPI.normalize_body(body)
      assert normalized["instructions"] == "be helpful"
    end

    test "is idempotent" do
      body = %{"model" => "gpt-5"}
      once = CodexAPI.normalize_body(body)
      twice = CodexAPI.normalize_body(once)
      assert once == twice
    end
  end

  # ══════════════════════════════════════════════════
  # CodexAPI.build_headers/3 — header casing & ordering parity
  # ══════════════════════════════════════════════════

  describe "CodexAPI.build_headers/3" do
    setup do
      account = %AvailableAccount{
        token: %TokenData{
          access_token: "test-token",
          email: "test@example.com",
          expires_at: "2099-01-01T00:00:00Z"
        },
        chatgpt_account_id: "acct-123"
      }

      config = %{cloaking: %{codex: %{}}}
      {:ok, account: account, config: config}
    end

    test "uses Title-Case for ChatGPT-Account-ID (matches Node.js)", %{account: acct, config: cfg} do
      headers = CodexAPI.build_headers(acct, false, cfg)
      keys = Enum.map(headers, fn {k, _} -> k end)
      assert "ChatGPT-Account-ID" in keys
      refute "chatgpt-account-id" in keys
    end

    test "uses Title-Case for OpenAI-Beta when set", %{account: acct} do
      cfg = %{cloaking: %{codex: %{"openai-beta" => "responses=v1"}}}
      headers = CodexAPI.build_headers(acct, false, cfg)
      keys = Enum.map(headers, fn {k, _} -> k end)
      assert "OpenAI-Beta" in keys
    end

    test "uses Title-Case for Authorization, Accept, User-Agent, Content-Type", %{
      account: acct,
      config: cfg
    } do
      headers = CodexAPI.build_headers(acct, false, cfg)
      keys = Enum.map(headers, fn {k, _} -> k end)
      assert "Content-Type" in keys
      assert "Authorization" in keys
      assert "Accept" in keys
      assert "User-Agent" in keys
    end

    test "header order matches Node.js: Content-Type, Authorization, Accept, User-Agent, originator, version, then optional",
         %{account: acct, config: cfg} do
      headers = CodexAPI.build_headers(acct, false, cfg)
      keys = Enum.map(headers, fn {k, _} -> k end)
      # First 6 in fixed order
      assert Enum.take(keys, 6) == [
               "Content-Type",
               "Authorization",
               "Accept",
               "User-Agent",
               "originator",
               "version"
             ]
    end

    test "lowercase 'originator' and 'version' (codex CLI uses lowercase)", %{
      account: acct,
      config: cfg
    } do
      headers = CodexAPI.build_headers(acct, false, cfg)
      keys = Enum.map(headers, fn {k, _} -> k end)
      assert "originator" in keys
      assert "version" in keys
    end

    test "does NOT include ChatGPT-Account-ID when not set", %{config: cfg} do
      account = %AvailableAccount{
        token: %TokenData{
          access_token: "tok",
          email: "test@example.com",
          expires_at: "2099-01-01T00:00:00Z"
        }
      }

      headers = CodexAPI.build_headers(account, false, cfg)
      keys = Enum.map(headers, fn {k, _} -> k end)
      refute "ChatGPT-Account-ID" in keys
      refute "chatgpt-account-id" in keys
    end

    test "Accept header switches to text/event-stream when stream=true", %{
      account: acct,
      config: cfg
    } do
      headers = CodexAPI.build_headers(acct, true, cfg)
      assert {"Accept", "text/event-stream"} in headers
    end

    test "Accept header is application/json when stream=false", %{account: acct, config: cfg} do
      headers = CodexAPI.build_headers(acct, false, cfg)
      assert {"Accept", "application/json"} in headers
    end
  end

  # ══════════════════════════════════════════════════
  # AnthropicAPI.build_headers — parity with Node.js header casing
  # (build_headers is private; we exercise it via call_anthropic_messages
  # in integration tests. Here we test the case via a public helper.)
  # ══════════════════════════════════════════════════

  describe "AnthropicAPI header casing" do
    test "X-Stainless-Retry-Count defaults to 0 when no attempt stashed" do
      # Clear any stashed retry attempt
      Process.delete(:__auth2api_ex_retry_attempt)

      headers =
        AnthropicAPI.build_headers_for_test(
          "tok",
          false,
          60_000,
          "claude-sonnet-4-6",
          %{},
          "deadbeef",
          false,
          nil
        )

      retry_count =
        Enum.find_value(headers, fn {k, v} ->
          k == "X-Stainless-Retry-Count" && v
        end)

      assert retry_count == "0"
    end

    test "X-Stainless-Retry-Count reflects stashed attempt from proxy_with_retry" do
      try do
        Process.put(:__auth2api_ex_retry_attempt, 2)

        headers =
          AnthropicAPI.build_headers_for_test(
            "tok",
            false,
            60_000,
            "claude-sonnet-4-6",
            %{},
            "deadbeef",
            false,
            nil
          )

        retry_count =
          Enum.find_value(headers, fn {k, v} ->
            k == "X-Stainless-Retry-Count" && v
          end)

        assert retry_count == "2"
      after
        Process.delete(:__auth2api_ex_retry_attempt)
      end
    end

    test "exposes Title-Case via build_headers_for_test/8 (or equivalent)" do
      # The function should exist as a test helper or be public for parity testing.
      # Headers we expect Title-Case: Content-Type, Authorization, User-Agent,
      # X-Claude-Code-Session-Id, X-Stainless-*, Accept.
      headers =
        AnthropicAPI.build_headers_for_test(
          "tok",
          false,
          60_000,
          "claude-sonnet-4-6",
          %{},
          "deadbeef",
          false,
          nil
        )

      keys = Enum.map(headers, fn {k, _} -> k end)
      assert "Content-Type" in keys
      assert "Authorization" in keys
      assert "User-Agent" in keys
      assert "X-Claude-Code-Session-Id" in keys
      assert "X-Stainless-Lang" in keys
      assert "X-Stainless-Package-Version" in keys
      assert "X-Stainless-Os" in keys
      assert "X-Stainless-Arch" in keys
      assert "X-Stainless-Timeout" in keys
      assert "X-Stainless-Retry-Count" in keys
      assert "Accept" in keys
      # Lowercase headers (per real Claude Code mitm capture)
      assert "anthropic-dangerous-direct-browser-access" in keys
      assert "anthropic-version" in keys
      assert "anthropic-beta" in keys
      assert "x-app" in keys
      assert "x-client-request-id" in keys
    end

    test "deduplicates oauth beta when forwarding passthrough anthropic-beta" do
      headers =
        AnthropicAPI.build_headers_for_test(
          "tok",
          false,
          60_000,
          "claude-sonnet-4-6",
          %{},
          "deadbeef",
          false,
          %{"anthropic-beta" => "oauth-2025-04-20,claude-code-20250219"}
        )

      beta = Enum.find_value(headers, fn {k, v} -> if k == "anthropic-beta", do: v end)

      assert beta == "oauth-2025-04-20,claude-code-20250219"
    end
  end

  # ══════════════════════════════════════════════════
  # OpenAI error body adapter (parity with Node.js openaiErrorBody)
  # ══════════════════════════════════════════════════

  describe "HTTP.openai_error_body/2" do
    test "translates Anthropic error body to OpenAI shape" do
      body = ~s({"type":"error","error":{"type":"rate_limit_error","message":"slow down"}})
      result = HTTP.openai_error_body(429, body)
      assert get_in(result, [:error, :message]) == "slow down"
      assert get_in(result, [:error, :type]) == "rate_limit_error"
    end

    test "translates Codex {detail: ...} body to OpenAI shape" do
      body = ~s({"detail":"This model requires a newer Codex version"})
      result = HTTP.openai_error_body(400, body)
      assert get_in(result, [:error, :message]) == "This model requires a newer Codex version"
      assert get_in(result, [:error, :type]) == "upstream_error"
    end

    test "uses fallback message for invalid JSON" do
      result = HTTP.openai_error_body(500, "<html>Bad Gateway</html>")
      assert get_in(result, [:error, :message]) == "Upstream request failed"
      assert get_in(result, [:error, :type]) == "upstream_error"
    end

    test "uses fallback for empty body" do
      result = HTTP.openai_error_body(502, "")
      assert get_in(result, [:error, :message]) == "Upstream request failed"
    end

    test "handles deeply nested error.error.message" do
      body = ~s({"error":{"error":{"message":"nested"}}})
      result = HTTP.openai_error_body(500, body)
      assert get_in(result, [:error, :message]) == "nested"
    end
  end

  # ══════════════════════════════════════════════════
  # proxy_with_retry — error_adapter + Retry-After parity
  # ══════════════════════════════════════════════════

  describe "proxy_with_retry/5" do
    alias Auth2ApiEx.Accounts.Manager
    alias Auth2ApiEx.Auth.TokenData

    setup do
      auth_dir = "/tmp/proxy_retry_test_#{System.unique_integer([:positive])}"
      File.mkdir_p!(auth_dir)
      name = String.to_atom("proxy_test_#{System.unique_integer([:positive])}")
      {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)

      token = %TokenData{
        access_token: "at",
        refresh_token: "rt",
        email: "test@test.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "uuid"
      }

      Manager.add_account(name, token)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        after
          File.rm_rf!(auth_dir)
        end
      end)

      {:ok, manager: name}
    end

    test "applies error_adapter to translate Codex {detail: …} into OpenAI shape", %{
      manager: manager
    } do
      conn = Plug.Test.conn(:post, "/v1/chat/completions")
      config = test_config()

      codex_err = ~s({"detail":"requires a newer version of Codex"})

      response =
        HTTP.proxy_with_retry("Test", conn, config, manager,
          upstream: fn _account ->
            {:ok, %Req.Response{status: 400, headers: [], body: codex_err}}
          end,
          success: fn _, _ -> raise "success should not be called for 400" end,
          error_adapter: &HTTP.openai_error_body/2
        )

      assert response.status == 400
      body = Jason.decode!(response.resp_body)
      assert body["error"]["message"] == "requires a newer version of Codex"
      assert body["error"]["type"] == "upstream_error"
      # Original `detail` key should NOT leak through.
      refute Map.has_key?(body, "detail")
    end

    test "without error_adapter, upstream Codex body passes through verbatim (with `detail`)", %{
      manager: manager
    } do
      conn = Plug.Test.conn(:post, "/v1/messages")
      config = test_config()

      codex_err = ~s({"detail":"requires a newer version of Codex"})

      response =
        HTTP.proxy_with_retry("Test", conn, config, manager,
          upstream: fn _account ->
            {:ok, %Req.Response{status: 400, headers: [], body: codex_err}}
          end,
          success: fn _, _ -> raise "success should not be called" end
        )

      assert response.status == 400
      body = Jason.decode!(response.resp_body)
      assert body["detail"] == "requires a newer version of Codex"
      refute body["error"]
    end

    test "error_adapter falls back to default shape on invalid JSON upstream body", %{
      manager: manager
    } do
      conn = Plug.Test.conn(:post, "/v1/chat/completions")
      config = test_config()

      response =
        HTTP.proxy_with_retry("Test", conn, config, manager,
          upstream: fn _account ->
            {:ok, %Req.Response{status: 502, headers: [], body: "<html>Bad Gateway</html>"}}
          end,
          success: fn _, _ -> raise "should not be called" end,
          max_retries: 1,
          error_adapter: &HTTP.openai_error_body/2
        )

      assert response.status == 502
      body = Jason.decode!(response.resp_body)
      assert body["error"]["message"] == "Upstream request failed"
      assert body["error"]["type"] == "upstream_error"
    end

    test "forwards upstream Retry-After header on 429 after retries exhausted", %{
      manager: manager
    } do
      conn = Plug.Test.conn(:post, "/v1/messages")
      config = test_config()

      response =
        HTTP.proxy_with_retry("Test", conn, config, manager,
          max_retries: 1,
          upstream: fn _account ->
            {:ok,
             %Req.Response{
               status: 429,
               headers: [{"retry-after", "42"}],
               body: ~s({"error":"rate limited"})
             }}
          end,
          success: fn _, _ -> raise "should not be called" end
        )

      assert response.status == 429
      assert Plug.Conn.get_resp_header(response, "retry-after") == ["42"]
    end

    test "records quota_exhausted when upstream 429 body contains quota signal", %{
      manager: manager
    } do
      conn = Plug.Test.conn(:post, "/v1/messages")
      config = test_config()

      response =
        HTTP.proxy_with_retry("Test", conn, config, manager,
          max_retries: 1,
          upstream: fn _account ->
            {:ok,
             %Req.Response{
               status: 429,
               headers: [],
               body: ~s({"error":"quota exceeded"})
             }}
          end,
          success: fn _, _ -> raise "should not be called" end
        )

      assert response.status == 429

      assert eventually?(fn ->
               [snapshot] = Manager.get_snapshots(manager)
               snapshot.last_failure_kind == :quota_exhausted
             end)
    end

    test "forwards upstream Retry-After header on 503 after retries exhausted", %{
      manager: manager
    } do
      conn = Plug.Test.conn(:post, "/v1/messages")
      config = test_config()

      response =
        HTTP.proxy_with_retry("Test", conn, config, manager,
          max_retries: 1,
          upstream: fn _account ->
            {:ok, %Req.Response{status: 503, headers: [{"Retry-After", "10"}], body: ""}}
          end,
          success: fn _, _ -> raise "should not be called" end
        )

      assert response.status == 503
      assert Plug.Conn.get_resp_header(response, "retry-after") == ["10"]
    end

    test "no Retry-After set when upstream omitted it", %{manager: manager} do
      conn = Plug.Test.conn(:post, "/v1/messages")
      config = test_config()

      response =
        HTTP.proxy_with_retry("Test", conn, config, manager,
          max_retries: 1,
          upstream: fn _account ->
            {:ok, %Req.Response{status: 500, headers: [], body: ""}}
          end,
          success: fn _, _ -> raise "should not be called" end
        )

      assert response.status == 500
      assert Plug.Conn.get_resp_header(response, "retry-after") == []
    end

    defp test_config do
      %{
        debug: "off",
        cloaking: %{},
        timeouts: %{
          messages_ms: 60_000,
          stream_messages_ms: 600_000,
          count_tokens_ms: 30_000
        }
      }
    end

    defp eventually?(fun, attempts \\ 20)
    defp eventually?(_fun, 0), do: false

    defp eventually?(fun, attempts) do
      if fun.() do
        true
      else
        Process.sleep(10)
        eventually?(fun, attempts - 1)
      end
    end
  end

  # ══════════════════════════════════════════════════
  # Cloaking — cc_workload billing header injection
  # ══════════════════════════════════════════════════

  describe "Cloaking.generate_billing_header with cc_workload" do
    alias Auth2ApiEx.Upstream.Cloaking

    test "generates billing header without cc_workload when workload is nil" do
      header =
        Cloaking.generate_billing_header_for_test(
          [%{"role" => "user", "content" => "hello world"}],
          "2.1.88",
          "cli"
        )

      assert String.starts_with?(header, "x-anthropic-billing-header:")
      assert String.contains?(header, "cc_version=2.1.88.")
      assert String.contains?(header, "cc_entrypoint=cli;")
      refute String.contains?(header, "cc_workload")
    end

    test "includes cc_workload in billing header when workload is provided" do
      header =
        Cloaking.generate_billing_header_for_test(
          [%{"role" => "user", "content" => "hello world"}],
          "2.1.88",
          "cli",
          "web"
        )

      assert String.starts_with?(header, "x-anthropic-billing-header:")
      assert String.contains?(header, "cc_workload=web;")
    end

    test "cc_workload for cron-initiated requests" do
      header =
        Cloaking.generate_billing_header_for_test(
          [%{"role" => "user", "content" => "test"}],
          "2.1.88",
          "cron",
          "cron"
        )

      assert String.contains?(header, "cc_workload=cron;")
      assert String.contains?(header, "cc_entrypoint=cron;")
    end

    test "full header format matches Node.js pattern" do
      header =
        Cloaking.generate_billing_header_for_test(
          [%{"role" => "user", "content" => "What time is it?"}],
          "2.1.88",
          "cli",
          "cli"
        )

      # Expected format: x-anthropic-billing-header: cc_version=2.1.88.XXX; cc_entrypoint=cli; cc_workload=cli;
      assert header =~
               ~r/^x-anthropic-billing-header: cc_version=2\.1\.88\.[a-f0-9]{3}; cc_entrypoint=cli; cc_workload=cli;$/
    end
  end

  describe "Cloaking.derive_workload" do
    alias Auth2ApiEx.Upstream.Cloaking

    test "returns nil when x-auth2api_ex-workload header is missing" do
      conn = Plug.Test.conn(:post, "/v1/messages")
      assert Cloaking.derive_workload_for_test(conn) == nil
    end

    test "returns workload tag from x-auth2api_ex-workload header" do
      conn =
        Plug.Test.conn(:post, "/v1/messages")
        |> Plug.Conn.put_req_header("x-auth2api_ex-workload", "web")

      assert Cloaking.derive_workload_for_test(conn) == "web"
    end

    test "returns workload tag from x-auth2api_ex-workload header for cron" do
      conn =
        Plug.Test.conn(:post, "/v1/messages")
        |> Plug.Conn.put_req_header("x-auth2api_ex-workload", "cron")

      assert Cloaking.derive_workload_for_test(conn) == "cron"
    end
  end
end
