defmodule Auth2ApiEx.AuditLog do
  @moduledoc """
  Ring-buffer audit log for request/response debugging.

  Writes are async (GenServer.cast) — non-blocking for the HTTP path.
  Reads hit ETS directly — lock-free.
  Max 500 records; oldest evicted on overflow.
  """

  use GenServer

  require Logger

  @table_name :audit_log
  @max_records 500

  @type entry :: %{
          id: integer(),
          timestamp: String.t(),
          method: String.t(),
          path: String.t(),
          type: String.t(),
          model: String.t() | nil,
          provider: String.t(),
          account_email: String.t() | nil,
          status: integer(),
          duration_ms: integer(),
          error: String.t() | nil,
          input_tokens: integer(),
          output_tokens: integer(),
          stream: boolean(),
          session_key: String.t() | nil
        }

  # ── Public API ──

  @doc "Record a request log entry. Fire-and-forget (cast)."
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    GenServer.cast(__MODULE__, {:record, attrs})
  end

  @doc """
  List log entries with optional filtering.
  Options: limit (default 100), offset (default 0), status (nil | :"2xx" | :"4xx" | :"5xx" | integer)
  """
  @spec list(keyword()) :: [entry()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    status_filter = Keyword.get(opts, :status)

    try do
      :ets.tab2list(@table_name)
      |> Enum.sort_by(fn {id, _} -> id end, :desc)
      |> apply_filter(status_filter)
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(fn {_id, entry} -> entry end)
    rescue
      ArgumentError -> []
    end
  end

  @doc "Clear all log entries."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc "Get total record count (ETS read)."
  @spec count() :: integer()
  def count do
    try do
      :ets.info(@table_name, :size)
    rescue
      ArgumentError -> 0
    end
  end

  # ── GenServer ──

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:ordered_set, :public, :named_table, read_concurrency: true])
    {:ok, %{counter: 0, max: @max_records}}
  end

  @impl true
  def handle_cast({:record, attrs}, state) do
    counter = state.counter + 1
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    entry =
      attrs
      |> Map.take([
        :method,
        :path,
        :type,
        :model,
        :provider,
        :account_email,
        :status,
        :duration_ms,
        :error,
        :input_tokens,
        :output_tokens,
        :stream,
        :session_key
      ])
      |> Map.merge(%{id: counter, timestamp: timestamp})

    :ets.insert(@table_name, {counter, entry})

    if :ets.info(@table_name, :size) > state.max do
      smallest = :ets.first(@table_name)
      smallest && :ets.delete(@table_name, smallest)
    end

    {:noreply, %{state | counter: counter}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, %{state | counter: 0}}
  end

  # ── Private ──

  defp apply_filter(entries, nil), do: entries

  defp apply_filter(entries, :"2xx"),
    do: Enum.filter(entries, fn {_, e} -> e.status in 200..299 end)

  defp apply_filter(entries, :"4xx"),
    do: Enum.filter(entries, fn {_, e} -> e.status in 400..499 end)

  defp apply_filter(entries, :"5xx"),
    do: Enum.filter(entries, fn {_, e} -> e.status in 500..599 end)

  defp apply_filter(entries, status) when is_integer(status) do
    Enum.filter(entries, fn {_, e} -> e.status == status end)
  end
end
