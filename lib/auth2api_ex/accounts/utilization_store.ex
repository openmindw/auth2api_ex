defmodule Auth2ApiEx.Accounts.UtilizationStore do
  @moduledoc """
  DETS-backed persistence for per-account 5h/7d utilization snapshots.

  Values are stored as display percentages (0-100) for both Anthropic and
  Codex. Reset timestamps are RFC3339 strings and are interpreted on read so
  expired windows are restored as 0%.
  """

  use GenServer

  require Logger

  @default_dir "priv/usage_stats"
  @default_auto_save_ms 60_000

  defmodule State do
    @moduledoc false
    defstruct table_name: nil, table: nil
  end

  @type snapshot :: %{
          optional(:utilization_5h) => float() | nil,
          optional(:reset_5h) => String.t() | nil,
          optional(:utilization_7d) => float() | nil,
          optional(:reset_7d) => String.t() | nil,
          optional(:updated_at) => String.t() | nil,
          optional(:source) => String.t() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec get(pid() | atom(), String.t(), String.t()) :: snapshot() | nil
  def get(server \\ __MODULE__, provider, email) do
    GenServer.call(server, {:get, normalize_provider(provider), normalize_email(email)})
  end

  @spec put(pid() | atom(), String.t(), String.t(), map()) :: :ok
  def put(server \\ __MODULE__, provider, email, snapshot) when is_map(snapshot) do
    GenServer.call(
      server,
      {:put, normalize_provider(provider), normalize_email(email), normalize_snapshot(snapshot)}
    )
  end

  @spec delete(pid() | atom(), String.t(), String.t()) :: :ok
  def delete(server \\ __MODULE__, provider, email) do
    GenServer.call(server, {:delete, normalize_provider(provider), normalize_email(email)})
  end

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, @default_dir)
    auto_save_ms = Keyword.get(opts, :auto_save_ms, @default_auto_save_ms)
    name_suffix = inspect(self()) |> :erlang.phash2()
    table_name = :"auth2api_ex_account_utilization_#{name_suffix}"
    table = :"auth2api_ex_account_utilization_ets_#{name_suffix}"

    File.mkdir_p!(dir)
    :ets.new(table, [:set, :protected, :named_table])
    open_dets!(table_name, Path.join(dir, "account_utilization.dets"), auto_save_ms)
    :dets.to_ets(table_name, table)

    {:ok, %State{table_name: table_name, table: table}}
  end

  @impl true
  def handle_call({:get, provider, email}, _from, %State{} = state) do
    key = {provider, email}

    snapshot =
      case :ets.lookup(state.table, key) do
        [{^key, value}] -> normalize_snapshot(value)
        _ -> nil
      end

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call({:put, provider, email, snapshot}, _from, %State{} = state) do
    key = {provider, email}
    :ets.insert(state.table, {key, snapshot})
    :dets.insert(state.table_name, {key, snapshot})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, provider, email}, _from, %State{} = state) do
    key = {provider, email}
    :ets.delete(state.table, key)
    :dets.delete(state.table_name, key)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    :dets.sync(state.table_name)
    :dets.close(state.table_name)
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
          "Account utilization DETS open failed for #{path}: #{inspect(reason)}; backing up to #{backup}"
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

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    now = System.system_time(:millisecond)

    %{
      utilization_5h:
        normalize_utilization(
          Map.get(snapshot, :utilization_5h) || Map.get(snapshot, "utilization_5h"),
          Map.get(snapshot, :reset_5h) || Map.get(snapshot, "reset_5h"),
          now
        ),
      reset_5h: normalize_string(Map.get(snapshot, :reset_5h) || Map.get(snapshot, "reset_5h")),
      utilization_7d:
        normalize_utilization(
          Map.get(snapshot, :utilization_7d) || Map.get(snapshot, "utilization_7d"),
          Map.get(snapshot, :reset_7d) || Map.get(snapshot, "reset_7d"),
          now
        ),
      reset_7d: normalize_string(Map.get(snapshot, :reset_7d) || Map.get(snapshot, "reset_7d")),
      updated_at:
        normalize_string(Map.get(snapshot, :updated_at) || Map.get(snapshot, "updated_at")),
      source: normalize_string(Map.get(snapshot, :source) || Map.get(snapshot, "source"))
    }
  end

  defp normalize_snapshot(_), do: %{}

  defp normalize_utilization(nil, _reset_at, _now_ms), do: nil

  defp normalize_utilization(value, reset_at, now_ms) do
    if reset_expired?(reset_at, now_ms), do: 0.0, else: normalize_float(value)
  end

  defp reset_expired?(reset_at, now_ms) when is_binary(reset_at) and reset_at != "" do
    case DateTime.from_iso8601(reset_at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond) <= now_ms
      _ -> false
    end
  end

  defp reset_expired?(_reset_at, _now_ms), do: false

  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value * 1.0

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp normalize_float(_), do: nil

  defp normalize_provider(provider) when is_binary(provider) and provider != "", do: provider
  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(_), do: "anthropic"

  defp normalize_email(email) when is_binary(email), do: String.trim(email)
  defp normalize_email(_), do: ""

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil
end
