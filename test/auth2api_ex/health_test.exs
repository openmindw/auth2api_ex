defmodule Auth2ApiEx.HealthTest do
  use ExUnit.Case, async: false

  alias Auth2ApiEx.{Health, Accounts.Manager, Config}
  alias Auth2ApiEx.Auth.{TokenData, TokenStorage}

  setup do
    auth_dir = Path.join(System.tmp_dir!(), "auth2api_ex-health-#{System.system_time(:millisecond)}")
    File.mkdir_p!(auth_dir)

    on_exit(fn ->
      File.rm_rf!(auth_dir)
    end)

    {:ok, auth_dir: auth_dir}
  end

  defp make_token(overrides) do
    %TokenData{
      access_token: Map.get(overrides, :access_token, "access-token"),
      refresh_token: Map.get(overrides, :refresh_token, "refresh-token"),
      email: Map.get(overrides, :email, "test@example.com"),
      expires_at:
        Map.get(
          overrides,
          :expires_at,
          DateTime.utc_now() |> DateTime.add(24 * 60 * 60, :second) |> DateTime.to_iso8601()
        ),
      account_uuid: Map.get(overrides, :account_uuid, "test-uuid"),
      provider: Map.get(overrides, :provider, "anthropic")
    }
  end

  describe "Health.check_public/1" do
    test "returns minimal safe data — no emails, no errors, no cache counters", %{
      auth_dir: auth_dir
    } do
      TokenStorage.save_token(auth_dir, make_token(%{email: "a@example.com"}))
      TokenStorage.save_token(auth_dir, make_token(%{email: "b@example.com"}))

      {:ok, _mgr} =
        Manager.start_link(
          auth_dir: auth_dir,
          provider: "anthropic",
          name: :health_pub_anthro
        )

      on_exit(fn -> cleanup_manager(:health_pub_anthro) end)

      {:ok, _mgr2} =
        Manager.start_link(
          auth_dir: auth_dir,
          provider: "codex",
          name: :health_pub_codex
        )

      on_exit(fn -> cleanup_manager(:health_pub_codex) end)

      Manager.load(:health_pub_anthro)

      started_at = DateTime.utc_now() |> DateTime.add(-60, :second)
      Application.put_env(:auth2api_ex, :started_at, started_at)
      on_exit(fn -> Application.delete_env(:auth2api_ex, :started_at) end)

      registry = build_registry(:health_pub_anthro, :health_pub_codex)
      result = Health.check_public(registry)

      assert result.status == "ok"
      assert result.total_accounts == 2
      assert result.available_accounts == 2
      assert result.uptime_seconds >= 60
      assert result.uptime_seconds <= 62
      assert length(result.providers) == 2

      anthro = Enum.find(result.providers, &(&1.provider == "anthropic"))
      assert anthro.total_accounts == 2
      assert anthro.available_accounts == 2
      assert anthro.degraded_accounts == 0
      assert anthro.token_expired_count == 0
      refute Map.has_key?(anthro, :prompt_cache_keys)
      refute Map.has_key?(anthro, :cooldown_accounts)
      refute Map.has_key?(anthro, :token_expiry)

      codex = Enum.find(result.providers, &(&1.provider == "codex"))
      assert codex.total_accounts == 0

      refute Map.has_key?(result, "cache_usage_summary")
      refute Map.has_key?(result, :cache_usage_summary)
    end

    test "reports degraded when all accounts are in cooldown", %{auth_dir: auth_dir} do
      TokenStorage.save_token(auth_dir, make_token(%{email: "cool@example.com"}))
      TokenStorage.save_token(auth_dir, make_token(%{email: "down@example.com"}))

      {:ok, _mgr} =
        Manager.start_link(
          auth_dir: auth_dir,
          provider: "anthropic",
          name: :health_pub_degraded
        )

      on_exit(fn -> cleanup_manager(:health_pub_degraded) end)

      {:ok, _mgr2} =
        Manager.start_link(
          auth_dir: auth_dir,
          provider: "codex",
          name: :health_pub_degraded_codex
        )

      on_exit(fn -> cleanup_manager(:health_pub_degraded_codex) end)

      Manager.load(:health_pub_degraded)
      Manager.record_failure(:health_pub_degraded, "cool@example.com", :rate_limit, "test")
      Manager.record_failure(:health_pub_degraded, "down@example.com", :auth, "test")
      :sys.get_state(:health_pub_degraded)

      registry = build_registry(:health_pub_degraded, :health_pub_degraded_codex)
      result = Health.check_public(registry)

      assert result.status == "degraded"
      assert result.total_accounts == 2
      assert result.available_accounts == 0

      anthro = Enum.find(result.providers, &(&1.provider == "anthropic"))
      assert anthro.available_accounts == 0
      assert anthro.degraded_accounts == 2
    end
  end

  describe "Health.check_full/1" do
    test "returns full detail with per-account data", %{auth_dir: auth_dir} do
      TokenStorage.save_token(auth_dir, make_token(%{email: "a@example.com"}))
      TokenStorage.save_token(auth_dir, make_token(%{email: "b@example.com"}))

      {:ok, _mgr} =
        Manager.start_link(auth_dir: auth_dir, provider: "anthropic", name: :health_full_anthro)

      on_exit(fn -> cleanup_manager(:health_full_anthro) end)

      {:ok, _mgr2} =
        Manager.start_link(auth_dir: auth_dir, provider: "codex", name: :health_full_codex)

      on_exit(fn -> cleanup_manager(:health_full_codex) end)

      Manager.load(:health_full_anthro)

      registry = build_registry(:health_full_anthro, :health_full_codex)
      result = Health.check_full(registry)

      assert result.status == "ok"
      assert length(result.providers) == 2

      anthro = Enum.find(result.providers, &(&1.provider == "anthropic"))
      assert length(anthro.prompt_cache_keys) == 2
      assert anthro.prompt_cache_keys |> hd() |> Map.has_key?(:email)
      assert anthro.prompt_cache_keys |> hd() |> Map.has_key?(:plan_type)
      assert anthro.prompt_cache_keys |> hd() |> Map.has_key?(:token_remaining_seconds)
      assert anthro.token_expiry != nil

      assert %{accounts: _, description: _} = result.cache_usage_summary
      assert length(result.cache_usage_summary.accounts) == 2
    end

    test "includes cooldown account details with truncated errors", %{auth_dir: auth_dir} do
      TokenStorage.save_token(auth_dir, make_token(%{email: "cooled@example.com"}))

      {:ok, _mgr} =
        Manager.start_link(auth_dir: auth_dir, provider: "anthropic", name: :health_full_cool)

      on_exit(fn -> cleanup_manager(:health_full_cool) end)

      {:ok, _mgr2} =
        Manager.start_link(auth_dir: auth_dir, provider: "codex", name: :health_full_cool_codex)

      on_exit(fn -> cleanup_manager(:health_full_cool_codex) end)

      Manager.load(:health_full_cool)
      long_error = String.duplicate("x", 200)
      Manager.record_failure(:health_full_cool, "cooled@example.com", :rate_limit, long_error)
      :sys.get_state(:health_full_cool)

      registry = build_registry(:health_full_cool, :health_full_cool_codex)
      result = Health.check_full(registry)

      anthro = Enum.find(result.providers, &(&1.provider == "anthropic"))
      assert length(anthro.cooldown_accounts) == 1
      assert hd(anthro.cooldown_accounts).email == "cooled@example.com"
      assert hd(anthro.cooldown_accounts).failure_kind == :rate_limit
      # last_error should be truncated to 100 chars + "..."
      error = hd(anthro.cooldown_accounts).last_error
      assert error != nil
      assert byte_size(error) <= 103
    end
  end

  describe "GET /health (public, no auth)" do
    test "returns 200 with minimal safe data — no emails or cache counters", %{auth_dir: auth_dir} do
      TokenStorage.save_token(auth_dir, make_token(%{email: "ep@example.com"}))

      {:ok, _mgr} =
        Manager.start_link(auth_dir: auth_dir, provider: "anthropic", name: :health_ep_pub_anthro)

      on_exit(fn -> cleanup_manager(:health_ep_pub_anthro) end)

      {:ok, _mgr2} =
        Manager.start_link(auth_dir: auth_dir, provider: "codex", name: :health_ep_pub_codex)

      on_exit(fn -> cleanup_manager(:health_ep_pub_codex) end)

      Manager.load(:health_ep_pub_anthro)

      registry = build_registry(:health_ep_pub_anthro, :health_ep_pub_codex)
      Application.put_env(:auth2api_ex, :registry, registry)

      Application.put_env(:auth2api_ex, :config, %Config{
        host: "127.0.0.1",
        port: 0,
        auth_dir: auth_dir,
        api_keys: MapSet.new(),
        body_limit: "10mb",
        debug: "off"
      })

      on_exit(fn ->
        Application.delete_env(:auth2api_ex, :registry)
        Application.delete_env(:auth2api_ex, :config)
      end)

      conn =
        Plug.Test.conn(:get, "/health")
        |> Auth2ApiEx.Server.call([])

      assert conn.state == :sent
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert body["total_accounts"] == 1
      assert body["available_accounts"] == 1
      assert is_integer(body["uptime_seconds"])
      assert is_list(body["providers"])
      refute Map.has_key?(body, "cache_usage_summary")

      provider = hd(body["providers"])
      refute Map.has_key?(provider, "prompt_cache_keys")
      refute Map.has_key?(provider, "cooldown_accounts")
    end
  end

  describe "GET /healthz (admin basic auth)" do
    test "returns 401 without credentials", %{auth_dir: auth_dir} do
      {:ok, _mgr} =
        Manager.start_link(auth_dir: auth_dir, provider: "anthropic", name: :healthz_noauth)

      on_exit(fn -> cleanup_manager(:healthz_noauth) end)

      Application.put_env(:auth2api_ex, :config, %Config{
        host: "127.0.0.1",
        port: 0,
        auth_dir: auth_dir,
        admin_username: "admin",
        admin_password: "secret",
        api_keys: MapSet.new(),
        body_limit: "10mb",
        debug: "off"
      })

      on_exit(fn -> Application.delete_env(:auth2api_ex, :config) end)

      conn =
        Plug.Test.conn(:get, "/healthz")
        |> Auth2ApiEx.Server.call([])

      assert conn.state == :sent
      assert conn.status == 401
    end

    test "returns 401 with wrong credentials", %{auth_dir: auth_dir} do
      Application.put_env(:auth2api_ex, :config, %Config{
        host: "127.0.0.1",
        port: 0,
        auth_dir: auth_dir,
        admin_username: "admin",
        admin_password: "secret",
        api_keys: MapSet.new(),
        body_limit: "10mb",
        debug: "off"
      })

      on_exit(fn -> Application.delete_env(:auth2api_ex, :config) end)

      conn =
        Plug.Test.conn(:get, "/healthz")
        |> Plug.Conn.put_req_header("authorization", basic_auth("admin", "wrong"))
        |> Auth2ApiEx.Server.call([])

      assert conn.status == 401
    end

    test "returns 200 with full detail when authenticated with admin creds", %{auth_dir: auth_dir} do
      TokenStorage.save_token(auth_dir, make_token(%{email: "full@example.com"}))

      {:ok, _mgr} =
        Manager.start_link(auth_dir: auth_dir, provider: "anthropic", name: :healthz_auth_anthro)

      on_exit(fn -> cleanup_manager(:healthz_auth_anthro) end)

      {:ok, _mgr2} =
        Manager.start_link(auth_dir: auth_dir, provider: "codex", name: :healthz_auth_codex)

      on_exit(fn -> cleanup_manager(:healthz_auth_codex) end)

      Manager.load(:healthz_auth_anthro)

      registry = build_registry(:healthz_auth_anthro, :healthz_auth_codex)
      Application.put_env(:auth2api_ex, :registry, registry)

      Application.put_env(:auth2api_ex, :config, %Config{
        host: "127.0.0.1",
        port: 0,
        auth_dir: auth_dir,
        admin_username: "admin",
        admin_password: "secret",
        api_keys: MapSet.new(),
        body_limit: "10mb",
        debug: "off"
      })

      on_exit(fn ->
        Application.delete_env(:auth2api_ex, :registry)
        Application.delete_env(:auth2api_ex, :config)
      end)

      conn =
        Plug.Test.conn(:get, "/healthz")
        |> Plug.Conn.put_req_header("authorization", basic_auth("admin", "secret"))
        |> Auth2ApiEx.Server.call([])

      assert conn.state == :sent
      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert body["cache_usage_summary"] != nil
      assert is_list(body["cache_usage_summary"]["accounts"])

      provider = hd(body["providers"])
      assert is_list(provider["prompt_cache_keys"])
    end
  end

  # ── Helpers ──

  defp basic_auth(username, password) do
    "Basic " <> Base.encode64("#{username}:#{password}")
  end

  defp build_registry(anthro_name, codex_name) do
    anthro_provider = %{
      id: :anthropic,
      manager: anthro_name,
      matches_model?: fn _ -> false end,
      list_models: fn -> {:ok, []} end
    }

    codex_provider = %{
      id: :codex,
      manager: codex_name,
      matches_model?: fn _ -> false end,
      list_models: fn -> {:ok, []} end
    }

    %{
      providers: [anthro_provider, codex_provider],
      by_id: %{anthropic: anthro_provider, codex: codex_provider}
    }
  end

  defp cleanup_manager(name) do
    pid = Process.whereis(name)
    if pid && Process.alive?(pid), do: GenServer.stop(name)
  end
end
