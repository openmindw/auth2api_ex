defmodule Auth2ApiEx.UsageStatsTest do
  use ExUnit.Case, async: false

  alias Auth2ApiEx.UsageStats

  defp start_stats(dir) do
    name = String.to_atom("usage_stats_#{System.unique_integer([:positive])}")
    {:ok, pid} = UsageStats.start_link(name: name, dir: dir, auto_save_ms: 1000)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {name, pid}
  end

  test "records provider-aware totals and daily buckets and restores them from DETS" do
    dir =
      Path.join(System.tmp_dir!(), "auth2api_ex-usage-stats-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    {name, pid} = start_stats(dir)

    UsageStats.record(name, "codex", "me@example.com", "gpt-5.4-mini", %{
      input_tokens: 10,
      output_tokens: 4,
      cache_creation_input_tokens: 3,
      cache_creation_5m_tokens: 1,
      cache_creation_1h_tokens: 2,
      cache_read_input_tokens: 5,
      reasoning_output_tokens: 6
    })

    assert eventually(fn ->
             [row] = UsageStats.totals(name)

             row.provider == "codex" and
               row.email == "me@example.com" and
               row.model == "gpt-5.4-mini" and
               row.requests == 1 and
               row.input_tokens == 10 and
               row.output_tokens == 4 and
               row.cache_creation_input_tokens == 3 and
               row.cache_creation_5m_tokens == 1 and
               row.cache_creation_1h_tokens == 2 and
               row.cache_read_input_tokens == 5 and
               row.reasoning_output_tokens == 6
           end)

    today = Date.utc_today()
    [daily] = UsageStats.daily(name)
    assert daily.date == today
    assert daily.provider == "codex"
    assert daily.email == "me@example.com"
    assert daily.model == "gpt-5.4-mini"
    assert daily.requests == 1

    GenServer.stop(pid)

    restored_name = String.to_atom("usage_stats_restored_#{System.unique_integer([:positive])}")
    {:ok, restored_pid} = UsageStats.start_link(name: restored_name, dir: dir, auto_save_ms: 1000)

    on_exit(fn ->
      if Process.alive?(restored_pid), do: GenServer.stop(restored_pid)
      File.rm_rf!(dir)
    end)

    [restored] = UsageStats.totals(restored_name)
    assert restored.provider == "codex"
    assert restored.email == "me@example.com"
    assert restored.model == "gpt-5.4-mini"
    assert restored.requests == 1
    assert restored.input_tokens == 10
  end

  test "keeps same email and model separate across providers" do
    dir =
      Path.join(System.tmp_dir!(), "auth2api_ex-usage-stats-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    {name, _pid} = start_stats(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    UsageStats.record(name, "anthropic", "me@example.com", "shared-model", %{
      input_tokens: 11,
      cache_read_input_tokens: 7
    })

    UsageStats.record(name, "codex", "me@example.com", "shared-model", %{
      input_tokens: 13,
      cache_read_input_tokens: 2
    })

    assert eventually(fn ->
             rows = UsageStats.totals(name)
             length(rows) == 2
           end)

    rows = UsageStats.totals(name)
    anthro = Enum.find(rows, &(&1.provider == "anthropic"))
    codex = Enum.find(rows, &(&1.provider == "codex"))

    assert anthro.input_tokens == 11
    assert anthro.cache_read_input_tokens == 7
    assert codex.input_tokens == 13
    assert codex.cache_read_input_tokens == 2
  end

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
end
