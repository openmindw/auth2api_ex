defmodule Auth2ApiEx.Admin.ManagerTest do
  use ExUnit.Case

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Accounts.UtilizationStore
  alias Auth2ApiEx.Auth.TokenData
  alias Auth2ApiEx.Utils.HTTP.UtilizationInfo

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")

  setup do
    auth_dir = Path.join(System.tmp_dir!(), "mgr-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(auth_dir)
    name = String.to_atom("test_manager_#{System.unique_integer([:positive])}")
    store_name = String.to_atom("test_util_store_#{System.unique_integer([:positive])}")
    {:ok, store_pid} = UtilizationStore.start_link(name: store_name, dir: auth_dir)
    {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name, utilization_store: store_name)

    token = %TokenData{
      access_token: "at",
      refresh_token: "rt",
      email: "test@test.com",
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "uuid"
    }

    Manager.add_account(name, token)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
      File.rm_rf!(auth_dir)
    end)

    %{name: name, pid: pid, auth_dir: auth_dir, store: store_name}
  end

  describe "get_next_account/2 with session_key" do
    setup do
      auth_dir = Path.join(System.tmp_dir!(), "sess-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(auth_dir)
      name = String.to_atom("test_sticky_#{System.unique_integer([:positive])}")
      {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)

      t1 = %TokenData{
        access_token: "at1",
        refresh_token: "rt1",
        email: "alice@test.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "uuid-a"
      }

      t2 = %TokenData{
        access_token: "at2",
        refresh_token: "rt2",
        email: "bob@test.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "uuid-b"
      }

      Manager.add_account(name, t1)
      Manager.add_account(name, t2)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(auth_dir)
      end)

      %{name: name, pid: pid, auth_dir: auth_dir}
    end

    test "returns account without session_key (backward compat)", %{name: name} do
      result = Manager.get_next_account(name)
      assert result.account != nil
      assert result.account.token.email in ["alice@test.com", "bob@test.com"]
    end

    test "same session_key returns same account (sticky)", %{name: name} do
      Manager.bind_session(name, "sk1", "alice@test.com")

      results =
        Enum.map(1..10, fn _ ->
          Manager.get_next_account(name, "sk1")
        end)

      emails = Enum.map(results, fn r -> r.account.token.email end)
      assert Enum.uniq(emails) == ["alice@test.com"]
    end

    test "different session_keys stick to different accounts", %{name: name} do
      Manager.bind_session(name, "sk1", "alice@test.com")
      Manager.bind_session(name, "sk2", "bob@test.com")

      r1 = Manager.get_next_account(name, "sk1")
      r2 = Manager.get_next_account(name, "sk2")

      assert r1.account.token.email == "alice@test.com"
      assert r2.account.token.email == "bob@test.com"
    end

    test "sticky_miss flag indicates whether session had binding", %{name: name} do
      # No session key → sticky_miss true
      r1 = Manager.get_next_account(name)
      assert r1.sticky_miss == true

      # Bind then hit → sticky_miss false
      Manager.bind_session(name, "sk3", "alice@test.com")
      r2 = Manager.get_next_account(name, "sk3")
      assert r2.sticky_miss == false

      # Unknown session → sticky_miss true
      r3 = Manager.get_next_account(name, "unknown")
      assert r3.sticky_miss == true
    end
  end

  describe "bind_session/3" do
    setup do
      auth_dir = Path.join(System.tmp_dir!(), "bind-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(auth_dir)
      name = String.to_atom("test_bind_#{System.unique_integer([:positive])}")
      {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)

      t = %TokenData{
        access_token: "at",
        refresh_token: "rt",
        email: "test@test.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "uuid"
      }

      Manager.add_account(name, t)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(auth_dir)
      end)

      %{name: name, pid: pid, auth_dir: auth_dir}
    end

    test "binds session to email", %{name: name} do
      :ok = Manager.bind_session(name, "session-a", "test@test.com")
      result = Manager.get_next_account(name, "session-a")
      assert result.account.token.email == "test@test.com"
      assert result.sticky_miss == false
    end

    test "rebind replaces existing binding", %{name: name} do
      Manager.bind_session(name, "session-a", "test@test.com")
      Manager.bind_session(name, "session-a", "test@test.com")
      result = Manager.get_next_account(name, "session-a")
      assert result.sticky_miss == false
    end
  end

  describe "clear_session/2" do
    setup do
      auth_dir = Path.join(System.tmp_dir!(), "clear-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(auth_dir)
      name = String.to_atom("test_clear_#{System.unique_integer([:positive])}")
      {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)

      t = %TokenData{
        access_token: "at",
        refresh_token: "rt",
        email: "test@test.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "uuid"
      }

      Manager.add_account(name, t)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(auth_dir)
      end)

      %{name: name, pid: pid, auth_dir: auth_dir}
    end

    test "clears session binding", %{name: name} do
      Manager.bind_session(name, "sess", "test@test.com")
      :ok = Manager.clear_session(name, "sess")
      result = Manager.get_next_account(name, "sess")
      assert result.sticky_miss == true
    end

    test "clearing unknown session is a no-op", %{name: name} do
      assert :ok = Manager.clear_session(name, "nonexistent")
    end
  end

  describe "remove_account/2" do
    test "removes account from ETS and state", %{name: name} do
      assert Manager.account_count(name) == 1
      assert :ok = Manager.remove_account(name, "test@test.com")
      assert Manager.account_count(name) == 0
      assert Manager.get_snapshots(name) == []
    end

    test "deletes token file from disk", %{name: name, auth_dir: auth_dir} do
      files_before = File.ls!(auth_dir) |> Enum.filter(&String.ends_with?(&1, ".json"))
      assert length(files_before) == 1

      Manager.remove_account(name, "test@test.com")

      files_after = File.ls!(auth_dir) |> Enum.filter(&String.ends_with?(&1, ".json"))
      assert files_after == []
    end

    test "returns error for nonexistent account", %{name: name} do
      assert {:error, :not_found} = Manager.remove_account(name, "nope@nope.com")
    end
  end

  describe "record_utilization/3" do
    test "stores utilization data and reflects in snapshot", %{name: name} do
      info = %UtilizationInfo{
        utilization_5h: 0.85,
        reset_5h: "2099-05-01T14:30:00Z",
        utilization_7d: 0.42,
        reset_7d: "2099-05-05T08:00:00Z"
      }

      Manager.record_utilization(name, "test@test.com", info)
      Process.sleep(50)

      [snap] = Manager.get_snapshots(name)
      assert snap.utilization_5h == 85.0
      assert snap.reset_5h == "2099-05-01T14:30:00Z"
      assert snap.utilization_7d == 42.0
      assert snap.reset_7d == "2099-05-05T08:00:00Z"
    end

    test "persists utilization and restores it on load", %{
      name: name,
      auth_dir: auth_dir,
      store: store
    } do
      info = %UtilizationInfo{
        utilization_5h: 0.85,
        reset_5h: "2099-05-01T14:30:00Z",
        utilization_7d: 0.42,
        reset_7d: "2099-05-05T08:00:00Z"
      }

      Manager.record_utilization(name, "test@test.com", info)

      assert eventually(fn ->
               case UtilizationStore.get(store, "anthropic", "test@test.com") do
                 %{utilization_5h: 85.0, utilization_7d: 42.0} -> true
                 _ -> false
               end
             end)

      restored_name =
        String.to_atom("test_manager_restored_#{System.unique_integer([:positive])}")

      {:ok, restored_pid} =
        Manager.start_link(auth_dir: auth_dir, name: restored_name, utilization_store: store)

      on_exit(fn ->
        if Process.alive?(restored_pid), do: GenServer.stop(restored_pid)
      end)

      :ok = Manager.load(restored_name)
      [snap] = Manager.get_snapshots(restored_name)
      assert snap.utilization_5h == 85.0
      assert snap.utilization_7d == 42.0
    end

    test "remove_account deletes persisted utilization", %{name: name, store: store} do
      Manager.record_utilization(name, "test@test.com", %UtilizationInfo{utilization_5h: 0.5})

      assert eventually(fn ->
               UtilizationStore.get(store, "anthropic", "test@test.com") != nil
             end)

      assert :ok = Manager.remove_account(name, "test@test.com")
      assert UtilizationStore.get(store, "anthropic", "test@test.com") == nil
    end

    test "expired reset returns zero utilization in snapshot", %{name: name} do
      info = %UtilizationInfo{
        utilization_5h: 0.85,
        reset_5h: "2000-01-01T00:00:00Z",
        utilization_7d: 0.42,
        reset_7d: "2099-05-05T08:00:00Z"
      }

      Manager.record_utilization(name, "test@test.com", info)

      assert eventually(fn ->
               [snap] = Manager.get_snapshots(name)
               snap.utilization_5h == 0.0 and snap.utilization_7d == 42.0
             end)
    end

    test "ignores nil email silently", %{name: name} do
      info = %UtilizationInfo{utilization_5h: 0.5}
      Manager.record_utilization(name, "nonexistent@test.com", info)
      # should not crash
      [snap] = Manager.get_snapshots(name)
      assert snap.utilization_5h == nil
    end
  end

  describe "record_success/3" do
    test "extract_usage includes cache creation TTL details" do
      usage =
        Manager.extract_usage(%{
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "cache_creation_input_tokens" => 7,
            "cache_read_input_tokens" => 3,
            "reasoning_output_tokens" => 2,
            "cache_creation" => %{
              "ephemeral_5m_input_tokens" => 4,
              "ephemeral_1h_input_tokens" => 6
            }
          }
        })

      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
      assert usage.cache_creation_input_tokens == 7
      assert usage.cache_read_input_tokens == 3
      assert usage.reasoning_output_tokens == 2
      assert usage.cache_creation_5m_tokens == 4
      assert usage.cache_creation_1h_tokens == 6
    end

    test "extract_usage falls back to legacy cached_tokens and TTL cache creation total" do
      usage =
        Manager.extract_usage(%{
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "cached_tokens" => 9,
            "cache_creation" => %{
              "ephemeral_5m_input_tokens" => 4,
              "ephemeral_1h_input_tokens" => 6
            }
          }
        })

      assert usage.cache_read_input_tokens == 9
      assert usage.cache_creation_input_tokens == 10
      assert usage.cache_creation_5m_tokens == 4
      assert usage.cache_creation_1h_tokens == 6
    end

    test "handles partial usage maps without crashing", %{name: name} do
      usage = %{
        input_tokens: 1,
        output_tokens: 2,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0
      }

      Manager.record_success(name, "test@test.com", usage)
      Process.sleep(50)

      [snap] = Manager.get_snapshots(name)
      assert snap.total_successes == 1
      assert snap.total_input_tokens == 1
      assert snap.total_output_tokens == 2
      assert snap.total_reasoning_output_tokens == 0
    end

    test "records model usage into UsageStats when model metadata is provided", %{name: name} do
      stats_name = String.to_atom("manager_usage_stats_#{System.unique_integer([:positive])}")

      dir =
        Path.join(System.tmp_dir!(), "manager-usage-stats-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      {:ok, stats_pid} = Auth2ApiEx.UsageStats.start_link(name: stats_name, dir: dir)

      on_exit(fn ->
        if Process.alive?(stats_pid), do: GenServer.stop(stats_pid)
        File.rm_rf!(dir)
      end)

      Manager.record_success(
        name,
        "test@test.com",
        %{input_tokens: 8, output_tokens: 3},
        model: "gpt-5.4-mini",
        provider: "codex",
        usage_stats_server: stats_name
      )

      assert eventually(fn ->
               case Auth2ApiEx.UsageStats.totals(stats_name) do
                 [row] ->
                   row.provider == "codex" and row.email == "test@test.com" and row.model == "gpt-5.4-mini" and
                     row.input_tokens == 8 and row.output_tokens == 3

                 _ ->
                   false
               end
             end)
    end
  end

  describe "record_failure/4 with quota_exhausted" do
    test "accepts :quota_exhausted as failure kind", %{name: name} do
      Manager.record_failure(name, "test@test.com", :quota_exhausted, "quota exceeded")
      Process.sleep(50)

      [snap] = Manager.get_snapshots(name)
      assert snap.last_failure_kind == :quota_exhausted
    end
  end
end
