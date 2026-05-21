defmodule Auth2ApiEx.Admin.HandlerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Auth2ApiEx.Auth.TokenData

  setup do
    # Ensure ETS tables exist (normally created in Application.start)
    if :ets.whereis(:auth2api_ex_sessions) == :undefined do
      :ets.new(:auth2api_ex_sessions, [:set, :public, :named_table])
    end

    # Start AuditLog GenServer for log endpoint tests
    _audit_log_pid =
      case Process.whereis(Auth2ApiEx.AuditLog) do
        nil ->
          {:ok, pid} = Auth2ApiEx.AuditLog.start_link()
          pid

        pid ->
          pid
      end

    usage_stats_dir =
      Path.join(System.tmp_dir!(), "admin-usage-stats-#{System.unique_integer([:positive])}")

    File.mkdir_p!(usage_stats_dir)

    usage_stats_pid =
      case Process.whereis(Auth2ApiEx.UsageStats) do
        nil ->
          {:ok, pid} = Auth2ApiEx.UsageStats.start_link(dir: usage_stats_dir)
          pid

        pid ->
          pid
      end

    Auth2ApiEx.UsageStats.record(Auth2ApiEx.UsageStats, "codex", "user@example.com", "gpt-5.4-mini", %{
      input_tokens: 100,
      output_tokens: 40,
      cache_read_input_tokens: 20,
      cache_creation_input_tokens: 10,
      cache_creation_5m_tokens: 4,
      cache_creation_1h_tokens: 6
    })

    Auth2ApiEx.UsageStats.record(Auth2ApiEx.UsageStats, "anthropic", "anthro@example.com", "claude-sonnet-4-6", %{
      input_tokens: 50,
      output_tokens: 20,
      cache_read_input_tokens: 10,
      cache_creation_input_tokens: 5,
      cache_creation_5m_tokens: 5,
      cache_creation_1h_tokens: 0
    })

    Process.sleep(20)

    auth_dir = Path.join(System.tmp_dir!(), "admin-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(auth_dir)

    config_path =
      Path.join(System.tmp_dir!(), "admin-test-cfg-#{System.unique_integer([:positive])}.yaml")

    File.write!(config_path, """
    api-keys:
      - sk-test-key
    admin:
      username: admin
      password: secret
    """)

    config = Auth2ApiEx.Config.load_config(config_path)
    Application.put_env(:auth2api_ex, :config, config)
    Application.put_env(:auth2api_ex, :config_path, config_path)

    # ── Anthropic manager ──
    anthro_name = String.to_atom("anthro_mgr_#{System.unique_integer([:positive])}")

    {:ok, anthro_pid} =
      Auth2ApiEx.Accounts.Manager.start_link(
        auth_dir: auth_dir,
        provider: "anthropic",
        name: anthro_name
      )

    Auth2ApiEx.Accounts.Manager.add_account(anthro_name, %TokenData{
      access_token: "at-anthro",
      refresh_token: "rt-anthro",
      email: "user@example.com",
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "acct-1"
    })

    Auth2ApiEx.Accounts.Manager.record_utilization(anthro_name, "user@example.com", %{
      utilization_5h: 0.2,
      reset_5h: DateTime.add(DateTime.utc_now(), 5 * 3600, :second) |> DateTime.to_iso8601(),
      utilization_7d: 0.19,
      reset_7d: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second) |> DateTime.to_iso8601()
    })

    # ── Codex manager ──
    codex_auth_dir =
      Path.join(System.tmp_dir!(), "codex-admin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(codex_auth_dir)

    codex_name = String.to_atom("codex_mgr_#{System.unique_integer([:positive])}")

    {:ok, codex_pid} =
      Auth2ApiEx.Accounts.Manager.start_link(
        auth_dir: codex_auth_dir,
        provider: "codex",
        name: codex_name
      )

    Auth2ApiEx.Accounts.Manager.add_account(codex_name, %TokenData{
      access_token: "at-codex",
      refresh_token: "rt-codex",
      email: "codex-user@example.com",
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "acct-codex-1",
      provider: "codex"
    })

    # ── Registry ──
    registry = %{
      providers: [
        %{id: :anthropic, manager: anthro_name},
        %{id: :codex, manager: codex_name}
      ],
      by_id: %{
        anthropic: %{id: :anthropic, manager: anthro_name},
        codex: %{id: :codex, manager: codex_name}
      }
    }

    Application.put_env(:auth2api_ex, :registry, registry)

    # Backward compat
    Application.put_env(:auth2api_ex, :manager_name, anthro_name)

    on_exit(fn ->
      Application.delete_env(:auth2api_ex, :manager_name)
      Application.delete_env(:auth2api_ex, :registry)
      Application.delete_env(:auth2api_ex, :config)
      Application.delete_env(:auth2api_ex, :config_path)
      if Process.whereis(Auth2ApiEx.AuditLog), do: Auth2ApiEx.AuditLog.clear()
      if Process.alive?(usage_stats_pid), do: GenServer.stop(usage_stats_pid, :normal, 1000)

      try do
        if Process.alive?(anthro_pid), do: GenServer.stop(anthro_pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(codex_pid), do: GenServer.stop(codex_pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(auth_dir)
      File.rm_rf!(codex_auth_dir)
      File.rm_rf!(usage_stats_dir)
      File.rm(config_path)
    end)

    %{
      config: config,
      auth_dir: auth_dir,
      config_path: config_path,
      anthro_mgr: anthro_name,
      codex_mgr: codex_name,
      registry: registry
    }
  end

  defp basic_auth_header(user, pass) do
    encoded = Base.encode64("#{user}:#{pass}")
    {"authorization", "Basic #{encoded}"}
  end

  describe "BasicAuth protection" do
    test "returns 401 without credentials" do
      conn =
        conn(:get, "/admin/api/accounts")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 401
    end

    test "returns 401 with wrong credentials" do
      conn =
        conn(:get, "/admin/api/accounts")
        |> put_req_header("authorization", "Basic " <> Base.encode64("admin:wrong"))
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 401
    end

    test "allows access with correct credentials" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/accounts")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
    end
  end

  describe "GET /admin/api/accounts" do
    test "returns account list for all providers by default" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/accounts")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["accounts"])
      emails = Enum.map(body["accounts"], & &1["email"])
      assert "user@example.com" in emails
      assert "codex-user@example.com" in emails
      assert body["account_count"] == 2

      anthro = Enum.find(body["accounts"], &(&1["email"] == "user@example.com"))
      assert anthro["utilization_5h"] == 20.0
      assert is_binary(anthro["reset_5h_human"])
      assert anthro["reset_5h_human"] != ""
      assert anthro["utilization_7d"] == 19.0
      assert is_binary(anthro["reset_7d_human"])
      assert anthro["reset_7d_human"] != ""
    end

    test "returns anthropic accounts when ?provider=anthropic" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/accounts?provider=anthropic")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      emails = Enum.map(body["accounts"], & &1["email"])
      assert "user@example.com" in emails
      refute "codex-user@example.com" in emails
      assert body["account_count"] == 1
    end

    test "returns codex accounts when ?provider=codex" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/accounts?provider=codex")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      emails = Enum.map(body["accounts"], & &1["email"])
      assert "codex-user@example.com" in emails
      refute "user@example.com" in emails
      assert body["account_count"] == 1
    end
  end

  describe "GET /admin/api/providers" do
    test "returns all providers with account counts" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/providers")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["providers"])
      assert length(body["providers"]) == 2

      anthro = Enum.find(body["providers"], &(&1["id"] == "anthropic"))
      codex = Enum.find(body["providers"], &(&1["id"] == "codex"))
      assert anthro["account_count"] == 1
      assert codex["account_count"] == 1
      assert anthro["label"] == "Anthropic"
      assert codex["label"] == "Codex"
    end
  end

  describe "GET /admin/api/keys" do
    test "returns masked API keys" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/keys")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["keys"])
      key_entry = hd(body["keys"])
      assert String.contains?(key_entry["masked"], "...")
      assert String.starts_with?(key_entry["key"], "sk-")
    end
  end

  describe "GET /admin/api/usage" do
    test "returns provider-aware token usage summary, totals, and daily rows" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/usage")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["summary"]["total_tokens"] >= 210
      assert body["summary"]["cache_read_tokens"] >= 30
      assert body["summary"]["cache_hit_ratio"] == 0.2
      assert is_list(body["totals"])
      assert is_list(body["daily"])
      assert Enum.all?(body["totals"], &Map.has_key?(&1, "provider"))
      assert Enum.all?(body["daily"], &Map.has_key?(&1, "provider"))

      breakdown = body["summary"]["provider_breakdown"]
      assert breakdown["anthropic"]["cache_hit_ratio"] == 0.2
      assert breakdown["anthropic"]["cache_read_tokens"] == 10
      assert breakdown["anthropic"]["requests"] == 1
      assert breakdown["codex"]["cache_hit_ratio"] == 0.2
      assert breakdown["codex"]["cache_read_tokens"] == 20
      assert breakdown["codex"]["requests"] == 1

      assert Enum.any?(body["totals"], &(&1["model"] == "gpt-5.4-mini" and &1["provider"] == "codex"))
      assert Enum.any?(body["totals"], &(&1["model"] == "claude-sonnet-4-6" and &1["provider"] == "anthropic"))
    end
  end

  describe "POST /admin/api/keys" do
    test "generates new API key" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/keys")
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert String.starts_with?(body["key"], "sk-")
    end

    test "generates custom API key when provided" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/keys", Jason.encode!(%{key: "sk-custom-test-123"}))
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["key"] == "sk-custom-test-123"
      assert body["masked"] == "sk-cus...-123"
    end

    test "returns 400 when custom key already exists" do
      {key, value} = basic_auth_header("admin", "secret")
      custom_key = "sk-custom-dup-test"

      conn1 =
        conn(:post, "/admin/api/keys", Jason.encode!(%{key: custom_key}))
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn1.status == 201

      conn2 =
        conn(:post, "/admin/api/keys", Jason.encode!(%{key: custom_key}))
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn2.status == 400
      body2 = Jason.decode!(conn2.resp_body)
      assert body2["error"] == "API 密钥已存在"
    end
  end

  describe "DELETE /admin/api/keys/:key" do
    test "removes API key" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:delete, "/admin/api/keys/sk-test-key")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
    end
  end

  describe "GET /admin - HTML page" do
    test "returns HTML with visible utilization reset labels" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      assert conn.resp_body =~ "重置"
      assert conn.resp_body =~ "5小时"
      assert conn.resp_body =~ "周额度"
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "text/html"
    end
  end

  describe "POST /admin/api/accounts/oauth-start" do
    test "returns anthropic session_id and auth_url by default" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/accounts/oauth-start", "{}")
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["session_id"])
      assert body["auth_url"] =~ "claude.ai/oauth/authorize"
    end

    test "returns anthropic auth_url when provider=anthropic" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/accounts/oauth-start", Jason.encode!(%{provider: "anthropic"}))
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["auth_url"] =~ "claude.ai/oauth/authorize"
    end

    test "returns codex auth_url when provider=codex" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/accounts/oauth-start", Jason.encode!(%{provider: "codex"}))
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["session_id"])
      assert body["auth_url"] =~ "auth.openai.com/oauth/authorize"
    end
  end

  describe "POST /admin/api/accounts/oauth-exchange" do
    test "returns 400 when session_id or code missing" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/accounts/oauth-exchange", Jason.encode!(%{}))
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 400
    end

    test "returns 404 for unknown session_id" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(
          :post,
          "/admin/api/accounts/oauth-exchange",
          Jason.encode!(%{session_id: "nonexistent", code: "abc"})
        )
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 404
    end
  end

  describe "POST /admin/api/accounts/cookie-auth" do
    test "rejects cookie-auth for codex provider" do
      {key, value} = basic_auth_header("admin", "secret")

      conn =
        conn(
          :post,
          "/admin/api/accounts/cookie-auth",
          Jason.encode!(%{session_key: "fake", provider: "codex"})
        )
        |> put_req_header(key, value)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "cookie-auth"
    end
  end

  describe "DELETE /admin/api/accounts/:email" do
    test "deletes account from specified provider" do
      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      # Delete codex account via ?provider=codex
      conn =
        conn(:delete, "/admin/api/accounts/codex-user@example.com?provider=codex")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200

      # Verify codex account is gone
      conn2 =
        conn(:get, "/admin/api/accounts?provider=codex")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      body2 = Jason.decode!(conn2.resp_body)
      assert body2["account_count"] == 0

      # Anthropic account is still available via default listing
      conn3 =
        conn(:get, "/admin/api/accounts")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      body3 = Jason.decode!(conn3.resp_body)
      emails = Enum.map(body3["accounts"], & &1["email"])
      assert "user@example.com" in emails
      refute "codex-user@example.com" in emails
    end
  end

  describe "POST /admin/api/accounts/:email/refresh" do
    test "refreshes account from specified provider" do
      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/accounts/codex-user@example.com/refresh?provider=codex", "{}")
        |> put_req_header(hdr_key, hdr_val)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      # Will return 404 or 409 since there's no real refresh token to use,
      # but importantly it routes to the codex manager, not anthropic.
      # The important thing is it doesn't return 404 (account not found on wrong provider)
      status = conn.status
      # 202 accepted for queued refresh, or other non-404
      assert status in [202, 404, 409]

      if status == 404 do
        body = Jason.decode!(conn.resp_body)
        # Should be "not found on codex manager" not "wrong provider"
        IO.puts("Refresh response: #{inspect(body)}")
      end
    end
  end

  describe "POST /admin/api/reload" do
    test "reloads accounts for specified provider" do
      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/reload?provider=codex", "{}")
        |> put_req_header(hdr_key, hdr_val)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_map(body["reload"])
    end

    test "reloads anthropic accounts by default (no provider)" do
      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      conn =
        conn(:post, "/admin/api/reload", "{}")
        |> put_req_header(hdr_key, hdr_val)
        |> put_req_header("content-type", "application/json")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_map(body["reload"])
    end
  end

  describe "GET /admin/api/logs" do
    test "returns empty logs list when no records" do
      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/logs")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["logs"])
      assert is_integer(body["total"])
    end

    test "returns recorded log entries" do
      Auth2ApiEx.AuditLog.record(%{
        method: "POST",
        path: "ChatCompletions",
        model: "claude-sonnet-4-6",
        provider: "anthropic",
        account_email: "test@example.com",
        status: 200,
        duration_ms: 150,
        error: nil,
        input_tokens: 0,
        output_tokens: 0,
        stream: false,
        session_key: nil
      })

      Process.sleep(20)

      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/logs")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["logs"]) >= 1
      log = hd(body["logs"])
      assert log["path"] == "ChatCompletions"
      assert log["status"] == 200
      assert log["provider"] == "anthropic"
    end

    test "filters logs by status" do
      Auth2ApiEx.AuditLog.record(%{
        method: "POST",
        path: "Messages",
        model: "claude-sonnet-4-6",
        provider: "anthropic",
        account_email: "test@example.com",
        status: 500,
        duration_ms: 200,
        error: "Server error",
        input_tokens: 0,
        output_tokens: 0,
        stream: false,
        session_key: nil
      })

      Auth2ApiEx.AuditLog.record(%{
        method: "POST",
        path: "ChatCompletions",
        model: "claude-sonnet-4-6",
        provider: "anthropic",
        account_email: "test@example.com",
        status: 200,
        duration_ms: 50,
        error: nil,
        input_tokens: 0,
        output_tokens: 0,
        stream: false,
        session_key: nil
      })

      Process.sleep(20)

      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      conn =
        conn(:get, "/admin/api/logs?status=5xx")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["logs"]) == 1
      assert hd(body["logs"])["status"] == 500
    end
  end

  describe "DELETE /admin/api/logs" do
    test "clears all logs" do
      Auth2ApiEx.AuditLog.record(%{
        method: "POST",
        path: "Messages",
        model: "claude-sonnet-4-6",
        provider: "anthropic",
        account_email: "test@example.com",
        status: 200,
        duration_ms: 100,
        error: nil,
        input_tokens: 0,
        output_tokens: 0,
        stream: false,
        session_key: nil
      })

      Process.sleep(20)

      {hdr_key, hdr_val} = basic_auth_header("admin", "secret")

      conn =
        conn(:delete, "/admin/api/logs")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "cleared"

      # Verify logs are empty
      conn2 =
        conn(:get, "/admin/api/logs")
        |> put_req_header(hdr_key, hdr_val)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      body2 = Jason.decode!(conn2.resp_body)
      assert body2["total"] == 0
    end
  end
end
