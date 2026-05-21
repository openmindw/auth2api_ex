defmodule Auth2ApiEx.SmokeTest do
  use ExUnit.Case, async: false

  alias Auth2ApiEx.{Config, Accounts.Manager}
  alias Auth2ApiEx.Auth.{TokenData, TokenStorage}

  @test_key "test-key"

  setup do
    # Create temp auth dir
    auth_dir = Path.join(System.tmp_dir!(), "auth2api_ex-smoke-#{System.system_time(:millisecond)}")
    File.mkdir_p!(auth_dir)

    # Create test config
    config = %Config{
      host: "127.0.0.1",
      port: 0,
      auth_dir: auth_dir,
      api_keys: MapSet.new([@test_key]),
      body_limit: "200mb",
      cloaking: %{cli_version: "2.1.88", entrypoint: "cli"},
      timeouts: %{messages_ms: 120_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000},
      debug: "off"
    }

    on_exit(fn ->
      File.rm_rf!(auth_dir)
    end)

    {:ok, auth_dir: auth_dir, config: config}
  end

  defp make_token(overrides \\ %{}) do
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
      account_uuid: Map.get(overrides, :account_uuid, "test-uuid")
    }
  end

  describe "token storage" do
    test "saves and loads tokens", %{auth_dir: auth_dir} do
      token = make_token()
      :ok = TokenStorage.save_token(auth_dir, token)

      loaded = TokenStorage.load_all_tokens(auth_dir)
      assert length(loaded) == 1
      assert hd(loaded).email == "test@example.com"
      assert hd(loaded).access_token == "access-token"
    end

    test "loads multiple accounts", %{auth_dir: auth_dir} do
      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "first@example.com", access_token: "first-access"})
      )

      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "second@example.com", access_token: "second-access"})
      )

      loaded = TokenStorage.load_all_tokens(auth_dir)
      assert length(loaded) == 2
    end
  end

  describe "account manager" do
    test "loads accounts from auth dir", %{auth_dir: auth_dir} do
      TokenStorage.save_token(auth_dir, make_token())

      {:ok, _} = Manager.start_link(auth_dir: auth_dir, name: :smoke_manager)
      Manager.load(:smoke_manager)

      assert Manager.account_count(:smoke_manager) == 1

      GenServer.stop(:smoke_manager)
    end

    test "sticky selection keeps using the same account", %{auth_dir: auth_dir} do
      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "a@example.com", access_token: "token-a"})
      )

      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "b@example.com", access_token: "token-b"})
      )

      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "c@example.com", access_token: "token-c"})
      )

      {:ok, _} = Manager.start_link(auth_dir: auth_dir, name: :sticky_manager)
      Manager.load(:sticky_manager)

      # Without session_key — round-robin
      r1 = Manager.get_next_account(:sticky_manager)
      r2 = Manager.get_next_account(:sticky_manager)
      assert r1.account != nil
      assert r2.account != nil
      assert r1.sticky_miss == true
      assert r2.sticky_miss == true

      # With session_key — per-session sticky
      Manager.bind_session(:sticky_manager, "sk-a", "a@example.com")
      first = Manager.get_next_account(:sticky_manager, "sk-a")
      second = Manager.get_next_account(:sticky_manager, "sk-a")
      third = Manager.get_next_account(:sticky_manager, "sk-a")
      assert first.account != nil
      assert second.account != nil
      assert third.account != nil
      assert first.account.token.email == second.account.token.email
      assert first.account.token.email == third.account.token.email
      assert first.sticky_miss == false

      GenServer.stop(:sticky_manager)
    end

    test "returns failure info when all accounts are cooled down", %{auth_dir: auth_dir} do
      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "a@example.com", access_token: "token-a"})
      )

      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "b@example.com", access_token: "token-b"})
      )

      {:ok, _} = Manager.start_link(auth_dir: auth_dir, name: :cooldown_manager)
      Manager.load(:cooldown_manager)

      Manager.record_failure(:cooldown_manager, "a@example.com", :rate_limit, "test")
      Manager.record_failure(:cooldown_manager, "b@example.com", :rate_limit, "test")
      # flush casts before ETS read
      :sys.get_state(:cooldown_manager)

      result = Manager.get_next_account(:cooldown_manager)
      assert result.account == nil
      assert result.failure_kind == :rate_limit
      assert result.retry_after_ms != nil and result.retry_after_ms > 0

      GenServer.stop(:cooldown_manager)
    end

    test "prefers recoverable failure over terminal when all accounts down", %{auth_dir: auth_dir} do
      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "a@example.com", access_token: "token-a"})
      )

      TokenStorage.save_token(
        auth_dir,
        make_token(%{email: "b@example.com", access_token: "token-b"})
      )

      {:ok, _} = Manager.start_link(auth_dir: auth_dir, name: :priority_manager)
      Manager.load(:priority_manager)

      Manager.record_failure(:priority_manager, "a@example.com", :auth, "test")
      Manager.record_failure(:priority_manager, "b@example.com", :rate_limit, "test")
      # flush casts before ETS read
      :sys.get_state(:priority_manager)

      result = Manager.get_next_account(:priority_manager)
      assert result.account == nil
      assert result.failure_kind == :rate_limit

      GenServer.stop(:priority_manager)
    end
  end

  describe "config" do
    test "loadConfig converts YAML api-keys array to MapSet" do
      config_path =
        Path.join(System.tmp_dir!(), "auth2api_ex-test-#{System.system_time(:millisecond)}.yaml")

      File.write!(config_path, """
      host: "127.0.0.1"
      port: 9999
      auth-dir: "~/.auth2api_ex"
      api-keys:
        - "sk-key-one"
        - "sk-key-two"
        - "sk-key-three"
      body-limit: "100mb"
      debug: "off"
      """)

      try do
        config = Config.load_config(config_path)
        assert config.port == 9999
        assert MapSet.member?(config.api_keys, "sk-key-one")
        assert MapSet.member?(config.api_keys, "sk-key-two")
        assert MapSet.member?(config.api_keys, "sk-key-three")
      after
        File.rm(config_path)
      end
    end
  end
end
