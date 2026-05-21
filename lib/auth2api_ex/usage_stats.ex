defmodule Auth2ApiEx.UsageStats do
  @moduledoc """
  Small personal-use token usage store backed by ETS + DETS.

  Tracks aggregate usage by `{provider, email, model}` and daily buckets by
  `{date, provider, email, model}`. This intentionally avoids SQLite/Postgres.
  """

  use GenServer

  require Logger

  @default_dir "priv/usage_stats"
  @default_auto_save_ms 60_000
  @default_retention_days 30

  defmodule State do
    @moduledoc false
    defstruct dir: nil,
              total_name: nil,
              daily_name: nil,
              total_table: nil,
              daily_table: nil,
              retention_days: 30
  end

  @empty %{
    requests: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_creation_5m_tokens: 0,
    cache_creation_1h_tokens: 0,
    cache_read_input_tokens: 0,
    reasoning_output_tokens: 0,
    total_duration_ms: 0,
    last_at: nil
  }

  @doc """
  Start the usage stats process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Record a completed request.
  """
  def record(server \\ __MODULE__, provider, email, model, usage, opts \\ []) do
    GenServer.cast(server, {:record, provider, email, model, usage, opts})
  end

  @doc """
  Return all aggregate rows sorted by email/model.
  """
  def totals(server \\ __MODULE__) do
    GenServer.call(server, :totals)
  end

  @doc """
  Return daily rows sorted by date/email/model.
  """
  def daily(server \\ __MODULE__) do
    GenServer.call(server, :daily)
  end

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, @default_dir)
    auto_save_ms = Keyword.get(opts, :auto_save_ms, @default_auto_save_ms)
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    name_suffix = inspect(self()) |> :erlang.phash2()
    total_name = :"auth2api_ex_usage_total_#{name_suffix}"
    daily_name = :"auth2api_ex_usage_daily_#{name_suffix}"
    total_table = :"auth2api_ex_usage_total_ets_#{name_suffix}"
    daily_table = :"auth2api_ex_usage_daily_ets_#{name_suffix}"

    File.mkdir_p!(dir)
    :ets.new(total_table, [:set, :protected, :named_table])
    :ets.new(daily_table, [:set, :protected, :named_table])

    open_dets!(total_name, Path.join(dir, "usage_total_v2.dets"), auto_save_ms)
    open_dets!(daily_name, Path.join(dir, "usage_daily_v2.dets"), auto_save_ms)

    :dets.to_ets(total_name, total_table)
    :dets.to_ets(daily_name, daily_table)

    {:ok,
     %State{
       dir: dir,
       total_name: total_name,
       daily_name: daily_name,
       total_table: total_table,
       daily_table: daily_table,
       retention_days: retention_days
     }}
  end

  @impl true
  def handle_cast({:record, provider, email, model, usage, opts}, %State{} = state) do
    provider = normalize_string(provider, "anthropic")
    email = normalize_string(email, "unknown")
    model = normalize_string(model, "unknown")
    now = Keyword.get(opts, :now, DateTime.utc_now())
    date = DateTime.to_date(now)

    total_key = {provider, email, model}
    daily_key = {date, provider, email, model}

    total = bump(lookup(state.total_table, total_key), usage, now)
    daily = bump(lookup(state.daily_table, daily_key), usage, nil)

    :ets.insert(state.total_table, {total_key, total})
    :ets.insert(state.daily_table, {daily_key, daily})
    :dets.insert(state.total_name, {total_key, total})
    :dets.insert(state.daily_name, {daily_key, daily})

    {:noreply, state}
  end

  @impl true
  def handle_call(:totals, _from, %State{} = state) do
    rows =
      state.total_table
      |> :ets.tab2list()
      |> Enum.map(fn {{provider, email, model}, value} ->
        value
        |> Map.put(:provider, provider)
        |> Map.put(:email, email)
        |> Map.put(:model, model)
      end)
      |> Enum.sort_by(fn row -> {row.provider, row.email, row.model} end)

    {:reply, rows, state}
  end

  @impl true
  def handle_call(:daily, _from, %State{} = state) do
    rows =
      state.daily_table
      |> :ets.tab2list()
      |> Enum.map(fn {{date, provider, email, model}, value} ->
        value
        |> Map.put(:date, date)
        |> Map.put(:provider, provider)
        |> Map.put(:email, email)
        |> Map.put(:model, model)
      end)
      |> Enum.sort_by(fn row -> {row.date, row.provider, row.email, row.model} end)

    {:reply, rows, state}
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    :dets.sync(state.total_name)
    :dets.sync(state.daily_name)
    :dets.close(state.total_name)
    :dets.close(state.daily_name)
    :ok
  end

  defp open_dets!(name, path, auto_save_ms) do
    case :dets.open_file(name,
           file: String.to_charlist(path),
           type: :set,
           auto_save: auto_save_ms
         ) do
      {:ok, ^name} ->
        :ok

      {:error, reason} ->
        backup = "#{path}.bak.#{System.system_time(:second)}"

        Logger.warning(
          "Usage DETS open failed for #{path}: #{inspect(reason)}; backing up to #{backup}"
        )

        if File.exists?(path), do: File.rename(path, backup)

        {:ok, ^name} =
          :dets.open_file(name,
            file: String.to_charlist(path),
            type: :set,
            auto_save: auto_save_ms
          )

        :ok
    end
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> normalize_row(value)
      _ -> @empty
    end
  end

  defp bump(row, usage, now) do
    row = normalize_row(row)

    row
    |> Map.update!(:requests, &(&1 + 1))
    |> add(:input_tokens, usage_value(usage, :input_tokens))
    |> add(:output_tokens, usage_value(usage, :output_tokens))
    |> add(:cache_creation_input_tokens, usage_value(usage, :cache_creation_input_tokens))
    |> add(:cache_creation_5m_tokens, usage_value(usage, :cache_creation_5m_tokens))
    |> add(:cache_creation_1h_tokens, usage_value(usage, :cache_creation_1h_tokens))
    |> add(:cache_read_input_tokens, usage_value(usage, :cache_read_input_tokens))
    |> add(:reasoning_output_tokens, usage_value(usage, :reasoning_output_tokens))
    |> add(:total_duration_ms, usage_value(usage, :duration_ms))
    |> maybe_put_last_at(now)
  end

  defp normalize_row(row) when is_map(row), do: Map.merge(@empty, row)
  defp normalize_row(_), do: @empty

  defp add(row, key, value), do: Map.update!(row, key, &(&1 + value))

  defp maybe_put_last_at(row, nil), do: Map.delete(row, :last_at)
  defp maybe_put_last_at(row, %DateTime{} = now), do: %{row | last_at: DateTime.to_iso8601(now)}

  defp usage_value(nil, _key), do: 0
  defp usage_value(usage, key) when is_map(usage), do: Map.get(usage, key, 0) || 0
  defp usage_value(_, _key), do: 0

  defp normalize_string(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp normalize_string(_, fallback), do: fallback
end
