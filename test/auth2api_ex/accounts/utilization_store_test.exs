defmodule Auth2ApiEx.Accounts.UtilizationStoreTest do
  use ExUnit.Case, async: false

  alias Auth2ApiEx.Accounts.UtilizationStore

  defp start_store(dir) do
    name = String.to_atom("util_store_#{System.unique_integer([:positive])}")
    {:ok, pid} = UtilizationStore.start_link(name: name, dir: dir, auto_save_ms: 1000)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {name, pid}
  end

  test "stores snapshots and restores them after DETS reopen" do
    dir =
      Path.join(System.tmp_dir!(), "auth2api_ex-util-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    {name, pid} = start_store(dir)

    :ok =
      UtilizationStore.put(name, "codex", "me@example.com", %{
        utilization_5h: 42.0,
        reset_5h: "2099-01-01T00:00:00Z",
        utilization_7d: 88.5,
        reset_7d: "2099-01-02T00:00:00Z",
        source: "codex_headers"
      })

    assert %{
             utilization_5h: 42.0,
             reset_5h: "2099-01-01T00:00:00Z",
             utilization_7d: 88.5,
             reset_7d: "2099-01-02T00:00:00Z"
           } = UtilizationStore.get(name, "codex", "me@example.com")

    GenServer.stop(pid)

    restored_name = String.to_atom("util_store_restored_#{System.unique_integer([:positive])}")

    {:ok, restored_pid} =
      UtilizationStore.start_link(name: restored_name, dir: dir, auto_save_ms: 1000)

    on_exit(fn ->
      if Process.alive?(restored_pid), do: GenServer.stop(restored_pid)
      File.rm_rf!(dir)
    end)

    assert %{utilization_5h: 42.0, utilization_7d: 88.5} =
             UtilizationStore.get(restored_name, "codex", "me@example.com")
  end

  test "expired reset timestamps restore utilization as zero" do
    dir =
      Path.join(System.tmp_dir!(), "auth2api_ex-util-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    {name, _pid} = start_store(dir)

    :ok =
      UtilizationStore.put(name, "codex", "me@example.com", %{
        utilization_5h: 42.0,
        reset_5h: "2000-01-01T00:00:00Z",
        utilization_7d: 88.0,
        reset_7d: "2099-01-01T00:00:00Z"
      })

    snapshot = UtilizationStore.get(name, "codex", "me@example.com")
    assert snapshot.utilization_5h == 0.0
    assert snapshot.utilization_7d == 88.0

    File.rm_rf!(dir)
  end

  test "deletes snapshots" do
    dir =
      Path.join(System.tmp_dir!(), "auth2api_ex-util-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    {name, _pid} = start_store(dir)

    :ok = UtilizationStore.put(name, "anthropic", "me@example.com", %{utilization_5h: 85.0})
    assert UtilizationStore.get(name, "anthropic", "me@example.com")

    :ok = UtilizationStore.delete(name, "anthropic", "me@example.com")
    assert UtilizationStore.get(name, "anthropic", "me@example.com") == nil

    File.rm_rf!(dir)
  end
end
