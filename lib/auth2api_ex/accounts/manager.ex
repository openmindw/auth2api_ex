defmodule Auth2ApiEx.Accounts.Manager do
  @moduledoc """
  GenServer managing account state, sticky selection, cooldown, and auto-refresh.

  Uses ETS for lock-free reads (get_next_account, get_snapshots, account_count).
  GenServer serializes all writes and dual-writes to ETS.
  """

  use GenServer

  require Logger

  alias Auth2ApiEx.Auth.{TokenData, TokenStorage}
  alias Auth2ApiEx.Accounts.UtilizationStore
  alias Auth2ApiEx.Utils.Common
  alias Auth2ApiEx.UsageStats

  @type failure_kind :: :rate_limit | :quota_exhausted | :auth | :forbidden | :server | :network

  @type usage_data :: %{
          input_tokens: integer(),
          output_tokens: integer(),
          cache_creation_input_tokens: integer(),
          cache_creation_5m_tokens: integer(),
          cache_creation_1h_tokens: integer(),
          cache_read_input_tokens: integer(),
          reasoning_output_tokens: integer()
        }

  defmodule AvailableAccount do
    @moduledoc """
    Struct representing an account ready for use in upstream requests.
    """
    defstruct token: nil,
              provider: nil,
              device_id: nil,
              account_uuid: nil,
              chatgpt_account_id: nil

    @type t :: %__MODULE__{
            token: TokenData.t(),
            provider: String.t() | nil,
            device_id: String.t(),
            account_uuid: String.t(),
            chatgpt_account_id: String.t() | nil
          }
  end

  @type available_account :: AvailableAccount.t()

  @type account_result ::
          %{account: available_account()}
          | %{account: nil, failure_kind: failure_kind() | nil, retry_after_ms: integer() | nil}

  @type account_result_unavailable :: %{
          account: nil,
          failure_kind: failure_kind() | nil,
          retry_after_ms: integer() | nil
        }

  @type account_snapshot :: %{
          email: String.t(),
          available: boolean(),
          cooldown_until: integer(),
          failure_count: integer(),
          last_error: String.t() | nil,
          last_failure_at: String.t() | nil,
          last_success_at: String.t() | nil,
          last_refresh_at: String.t() | nil,
          total_requests: integer(),
          total_successes: integer(),
          total_failures: integer(),
          total_input_tokens: integer(),
          total_output_tokens: integer(),
          total_cache_creation_input_tokens: integer(),
          total_cache_read_input_tokens: integer(),
          total_reasoning_output_tokens: integer(),
          expires_at: String.t(),
          plan_type: String.t() | nil,
          provider: String.t(),
          refreshing: boolean(),
          last_failure_kind: String.t() | nil,
          utilization_5h: float() | nil,
          reset_5h: String.t() | nil,
          utilization_7d: float() | nil,
          reset_7d: String.t() | nil
        }

  # Failure backoff configuration
  @failure_backoff %{
    rate_limit: %{base_ms: 60_000, max_ms: 900_000},
    quota_exhausted: %{base_ms: 7_200_000, max_ms: 18_000_000},
    auth: %{base_ms: 600_000, max_ms: 3_600_000},
    forbidden: %{base_ms: 600_000, max_ms: 3_600_000},
    server: %{base_ms: 5_000, max_ms: 300_000},
    network: %{base_ms: 5_000, max_ms: 300_000}
  }

  # Failure priority (lower = more recoverable)
  @failure_priority %{
    rate_limit: 0,
    quota_exhausted: 1,
    server: 2,
    network: 3,
    forbidden: 4,
    auth: 5
  }

  # Per-session sticky TTL
  @sticky_session_ttl_ms 60 * 60 * 1000

  # Refresh configuration
  @refresh_lead_ms 4 * 60 * 60 * 1000
  @refresh_check_interval_ms 60_000

  # ── Account state ──

  defmodule AccountState do
    @moduledoc false
    defstruct token: nil,
              cooldown_until: 0,
              failure_count: 0,
              last_failure_kind: nil,
              last_error: nil,
              last_failure_at: nil,
              last_success_at: nil,
              last_refresh_at: nil,
              total_requests: 0,
              total_successes: 0,
              total_failures: 0,
              total_input_tokens: 0,
              total_output_tokens: 0,
              total_cache_creation_input_tokens: 0,
              total_cache_read_input_tokens: 0,
              total_reasoning_output_tokens: 0,
              plan_type: nil,
              provider: "anthropic",
              refreshing: false,
              utilization_5h: nil,
              reset_5h: nil,
              utilization_7d: nil,
              reset_7d: nil,
              # Reauth terminal cooldown: set when refresh_token is permanently invalid
              reauth_cooldown_until: 0
  end

  # ── Server state ──

  defmodule State do
    @moduledoc false
    defstruct accounts: %{},
              account_order: [],
              last_used_index: -1,
              auth_dir: "",
              provider: "anthropic",
              refresh_fn: nil,
              refresh_policy: :expires_lead,
              refresh_policy_opts: %{lead_ms: 4 * 60 * 60 * 1000, since_last_ms: nil},
              utilization_store: Auth2ApiEx.Accounts.UtilizationStore,
              server_name: nil,
              accounts_table: nil,
              meta_table: nil,
              sticky_sessions_table: nil
  end

  # ── ETS table name derivation ──

  defp derive_table_names(__MODULE__),
    do: {:auth2api_ex_accounts, :auth2api_ex_manager_meta, :auth2api_ex_sticky_sessions}

  defp derive_table_names(name) when is_atom(name) do
    accounts = :"#{name}_accounts"
    meta = :"#{name}_meta"
    sticky = :"#{name}_sticky_sessions"
    {accounts, meta, sticky}
  end

  defp derive_table_names(_), do: derive_table_names(__MODULE__)

  @doc false
  def table_names(server \\ __MODULE__)
  def table_names(server) when is_atom(server), do: derive_table_names(server)
  def table_names(_), do: derive_table_names(__MODULE__)

  # ── Public API ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    auth_dir = Keyword.fetch!(opts, :auth_dir)
    provider = Keyword.get(opts, :provider, "anthropic")
    refresh_fn = Keyword.get(opts, :refresh_fn)
    name = Keyword.get(opts, :name, __MODULE__)
    utilization_store = Keyword.get(opts, :utilization_store, UtilizationStore)

    {refresh_policy, policy_opts} =
      case Keyword.get(opts, :refresh_policy, :expires_lead) do
        {:since_last_refresh, max_age_ms} ->
          {:since_last_refresh, %{lead_ms: @refresh_lead_ms, since_last_ms: max_age_ms}}

        :since_last_refresh ->
          {:since_last_refresh, %{lead_ms: @refresh_lead_ms, since_last_ms: 8 * 86_400_000}}

        :expires_lead ->
          {:expires_lead, %{lead_ms: @refresh_lead_ms, since_last_ms: nil}}

        {lead_ms} ->
          {:expires_lead, %{lead_ms: lead_ms, since_last_ms: nil}}
      end

    GenServer.start_link(
      __MODULE__,
      {auth_dir, provider, refresh_fn, refresh_policy, policy_opts, name, utilization_store},
      name: name
    )
  end

  @doc """
  Load accounts from the auth directory.
  """
  @spec load(pid() | atom()) :: :ok
  def load(server \\ __MODULE__) do
    GenServer.call(server, :load)
  end

  @doc """
  Add or update an account.
  """
  @spec add_account(pid() | atom(), TokenData.t()) :: :ok
  def add_account(server \\ __MODULE__, token) do
    GenServer.call(server, {:add_account, token})
  end

  @doc """
  Remove an account and its persisted token file.
  """
  @spec remove_account(pid() | atom(), String.t()) :: :ok | {:error, :not_found | any()}
  def remove_account(server \\ __MODULE__, email) do
    GenServer.call(server, {:remove_account, email})
  end

  @doc """
  Hot-reload accounts from disk — upsert semantics.
  Returns %{added: [...], updated: [...], unchanged: [...]}.
  """
  @spec reload(pid() | atom()) :: %{
          added: [String.t()],
          updated: [String.t()],
          unchanged: [String.t()]
        }
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  @doc """
  Get the next available account with optional per-session sticky binding.

  When session_key is provided:
  - If a sticky binding exists and account is available, returns that account and refreshes TTL.
  - If a sticky binding exists but account is temporarily cooling down, picks another but does NOT clear binding.
  - If a sticky binding exists but account has auth/forbidden permanent failure, clears binding and picks another.
  Returns %{account: ..., sticky_miss: true | false}.
  """
  @spec get_next_account(pid() | atom(), String.t() | nil) :: map()
  def get_next_account(server \\ __MODULE__, session_key \\ nil) do
    {accounts_table, meta_table, sticky_sessions_table} = table_names(server)
    ets_get_next_account(server, accounts_table, meta_table, sticky_sessions_table, session_key)
  end

  @doc """
  Bind a session key to an account email. Called after a successful request.
  Uses anti-overwrite protection: if session is already bound to a different email,
  the binding is only replaced if the cooldown of the new email suggests it's more available.
  """
  @spec bind_session(pid() | atom(), String.t(), String.t()) :: :ok
  def bind_session(server \\ __MODULE__, session_key, email) do
    GenServer.call(server, {:bind_sticky_session, session_key, email})
  end

  @doc """
  Clear a session binding. Called on auth/forbidden failures.
  """
  @spec clear_session(pid() | atom(), String.t()) :: :ok
  def clear_session(server \\ __MODULE__, session_key) do
    GenServer.call(server, {:clear_sticky_session, session_key})
  end

  @doc """
  Record a request attempt for an account.
  """
  @spec record_attempt(pid() | atom(), String.t()) :: :ok
  def record_attempt(server \\ __MODULE__, email) do
    GenServer.cast(server, {:record_attempt, email})
  end

  @doc """
  Record a successful request.
  """
  @spec record_success(pid() | atom(), String.t(), usage_data() | nil, keyword()) :: :ok
  def record_success(server \\ __MODULE__, email, usage \\ nil, opts \\ []) do
    GenServer.cast(server, {:record_success, email, usage, opts})
  end

  @doc """
  Record rate-limit utilization data for an account.
  """
  @spec record_utilization(pid() | atom(), String.t(), map()) :: :ok
  def record_utilization(server \\ __MODULE__, email, util_info) do
    GenServer.cast(server, {:record_utilization, email, util_info})
  end

  @doc """
  Record a failure and apply cooldown.
  """
  @spec record_failure(pid() | atom(), String.t(), failure_kind(), String.t() | nil) :: :ok
  def record_failure(server \\ __MODULE__, email, kind, detail \\ nil) do
    GenServer.cast(server, {:record_failure, email, kind, detail})
  end

  @doc """
  Refresh an account's token.
  """
  @spec refresh_account(pid() | atom(), String.t()) :: boolean()
  def refresh_account(server \\ __MODULE__, email) do
    GenServer.call(server, {:refresh_account, email}, 30_000)
  end

  @doc """
  Get account snapshots for admin endpoint.
  Reads directly from ETS — no GenServer call.
  """
  @spec get_snapshots(pid() | atom()) :: [account_snapshot()]
  def get_snapshots(server \\ __MODULE__) do
    {accounts_table, _meta_table, _sticky_table} = table_names(server)
    ets_get_snapshots(accounts_table)
  end

  @doc """
  Get the number of accounts.
  Reads directly from ETS — no GenServer call.
  """
  @spec account_count(pid() | atom()) :: integer()
  def account_count(server \\ __MODULE__) do
    {accounts_table, _meta_table, _sticky_table} = table_names(server)
    :ets.info(accounts_table, :size)
  end

  @doc """
  Extract usage data from an Anthropic response.
  """
  @spec extract_usage(map()) :: usage_data()
  def extract_usage(resp) do
    cache_creation_5m =
      get_in(resp, ["usage", "cache_creation", "ephemeral_5m_input_tokens"]) || 0

    cache_creation_1h =
      get_in(resp, ["usage", "cache_creation", "ephemeral_1h_input_tokens"]) || 0

    cache_creation_total =
      get_in(resp, ["usage", "cache_creation_input_tokens"]) ||
        cache_creation_5m + cache_creation_1h

    %{
      input_tokens: get_in(resp, ["usage", "input_tokens"]) || 0,
      output_tokens: get_in(resp, ["usage", "output_tokens"]) || 0,
      cache_creation_input_tokens: cache_creation_total,
      cache_creation_5m_tokens: cache_creation_5m,
      cache_creation_1h_tokens: cache_creation_1h,
      cache_read_input_tokens:
        get_in(resp, ["usage", "cache_read_input_tokens"]) ||
          get_in(resp, ["usage", "cached_tokens"]) || 0,
      reasoning_output_tokens: get_in(resp, ["usage", "reasoning_output_tokens"]) || 0
    }
  end

  # ══════════════════════════════════════════════════
  # ETS direct-read functions (no GenServer call)
  # ══════════════════════════════════════════════════

  defp ets_get_next_account(
         server,
         accounts_table,
         meta_table,
         sticky_sessions_table,
         session_key
       ) do
    case :ets.lookup(meta_table, :meta) do
      [{:meta, account_order, last_used_index, auth_dir}] ->
        count = length(account_order)

        if count == 0 do
          %{account: nil, failure_kind: nil, retry_after_ms: nil, sticky_miss: true}
        else
          now = System.system_time(:millisecond)

          # Try per-session sticky binding first
          if is_binary(session_key) and session_key != "" do
            case :ets.lookup(sticky_sessions_table, session_key) do
              [{^session_key, email, _ttl}] ->
                case :ets.lookup(accounts_table, email) do
                  [{^email, acct}] when acct.cooldown_until <= now ->
                    # Hit: account is available, refresh TTL
                    GenServer.cast(server, {:refresh_sticky_session, session_key})

                    %{
                      account: build_available_account(auth_dir, email, acct.token),
                      sticky_miss: false
                    }

                  [{^email, acct}] when acct.last_failure_kind in [:auth, :forbidden] ->
                    # Account permanently failed — clear binding and round-robin
                    GenServer.cast(server, {:clear_sticky_session, session_key})

                    ets_find_next_available(
                      server,
                      accounts_table,
                      account_order,
                      last_used_index,
                      auth_dir,
                      now
                    )
                    |> Map.put(:sticky_miss, true)

                  _ ->
                    # Account cooling down temporarily — keep binding, pick another
                    ets_find_next_available(
                      server,
                      accounts_table,
                      account_order,
                      last_used_index,
                      auth_dir,
                      now
                    )
                    |> Map.put(:sticky_miss, false)
                end

              [] ->
                # No binding for this session key — round-robin
                ets_find_next_available(
                  server,
                  accounts_table,
                  account_order,
                  last_used_index,
                  auth_dir,
                  now
                )
                |> Map.put(:sticky_miss, true)
            end
          else
            # No session key — round-robin
            ets_find_next_available(
              server,
              accounts_table,
              account_order,
              last_used_index,
              auth_dir,
              now
            )
            |> Map.put(:sticky_miss, true)
          end
        end

      [] ->
        %{account: nil, failure_kind: nil, retry_after_ms: nil, sticky_miss: true}
    end
  end

  defp ets_find_next_available(
         server,
         accounts_table,
         account_order,
         last_used_index,
         auth_dir,
         now
       ) do
    count = length(account_order)
    start_idx = if last_used_index >= 0, do: last_used_index + 1, else: 0

    result =
      Enum.find_value(0..(count - 1), fn i ->
        idx = rem(start_idx + i, count)
        email = Enum.at(account_order, idx)

        case :ets.lookup(accounts_table, email) do
          [{^email, acct}] when acct.cooldown_until <= now ->
            %{account: build_available_account(auth_dir, email, acct.token), idx: idx}

          _ ->
            nil
        end
      end)

    case result do
      %{account: account, idx: idx} ->
        GenServer.cast(server, {:update_round_robin, idx})
        %{account: account}

      nil ->
        ets_find_most_recoverable(accounts_table, account_order, now)
    end
  end

  defp ets_find_most_recoverable(_accounts_table, [], _now) do
    %{account: nil, failure_kind: nil, retry_after_ms: nil}
  end

  defp ets_find_most_recoverable(accounts_table, account_order, now) do
    {best_kind, best_remaining_ms} =
      Enum.reduce(account_order, {nil, nil}, fn email, {best_kind, best_remaining} ->
        case :ets.lookup(accounts_table, email) do
          [{^email, acct}] ->
            kind = acct.last_failure_kind || :network
            remaining = max(0, acct.cooldown_until - now)

            if is_nil(best_kind) or
                 @failure_priority[kind] < @failure_priority[best_kind] or
                 (@failure_priority[kind] == @failure_priority[best_kind] and
                    remaining < (best_remaining || :infinity)) do
              {kind, remaining}
            else
              {best_kind, best_remaining}
            end

          [] ->
            {best_kind, best_remaining}
        end
      end)

    is_recoverable = best_kind not in [:auth, :forbidden]

    %{
      account: nil,
      failure_kind: best_kind,
      retry_after_ms: if(is_recoverable, do: best_remaining_ms, else: nil)
    }
  end

  defp ets_get_snapshots(accounts_table) do
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {_email, acct}, acc ->
        provider = acct.provider || acct.token.provider || "anthropic"

        snapshot = %{
          email: acct.token.email,
          available: acct.cooldown_until <= now,
          cooldown_until: acct.cooldown_until,
          failure_count: acct.failure_count,
          last_error: acct.last_error,
          last_failure_at: acct.last_failure_at,
          last_success_at: acct.last_success_at,
          last_refresh_at: acct.last_refresh_at,
          total_requests: acct.total_requests,
          total_successes: acct.total_successes,
          total_failures: acct.total_failures,
          total_input_tokens: acct.total_input_tokens,
          total_output_tokens: acct.total_output_tokens,
          total_cache_creation_input_tokens: acct.total_cache_creation_input_tokens,
          total_cache_read_input_tokens: acct.total_cache_read_input_tokens,
          total_reasoning_output_tokens: acct.total_reasoning_output_tokens,
          expires_at: acct.token.expires_at,
          plan_type: acct.token.plan_type,
          provider: provider,
          refreshing: acct.refreshing,
          last_failure_kind: acct.last_failure_kind,
          utilization_5h:
            normalized_utilization(acct.utilization_5h, acct.reset_5h, provider, now),
          reset_5h: acct.reset_5h,
          utilization_7d:
            normalized_utilization(acct.utilization_7d, acct.reset_7d, provider, now),
          reset_7d: acct.reset_7d
        }

        [snapshot | acc]
      end,
      [],
      accounts_table
    )
  end

  defp normalized_utilization(nil, _reset_at, _provider, _now_ms), do: nil

  defp normalized_utilization(value, reset_at, provider, now_ms)
       when is_binary(reset_at) and reset_at != "" do
    reset_expired? =
      case DateTime.from_iso8601(reset_at) do
        {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond) <= now_ms
        _ -> false
      end

    if reset_expired? do
      0.0
    else
      normalize_percent_value(value, provider)
    end
  end

  defp normalized_utilization(value, _reset_at, provider, _now_ms) do
    normalize_percent_value(value, provider)
  end

  defp normalize_percent_value(value, provider) when is_number(value) do
    if provider == "anthropic" and value <= 1.0 do
      value * 100
    else
      value * 1.0
    end
  end

  defp normalize_percent_value(_value, _provider), do: nil

  # ══════════════════════════════════════════════════
  # GenServer callbacks
  # ══════════════════════════════════════════════════

  @impl true
  def init({auth_dir, provider, refresh_fn, refresh_policy, policy_opts, name, utilization_store}) do
    {accounts_table, meta_table, sticky_sessions_table} = derive_table_names(name)

    accounts_table =
      :ets.new(accounts_table, [:set, :public, :named_table, read_concurrency: true])

    meta_table = :ets.new(meta_table, [:set, :public, :named_table, read_concurrency: true])

    sticky_sessions_table =
      :ets.new(sticky_sessions_table, [:set, :public, :named_table, read_concurrency: true])

    # Initialize meta with empty state
    :ets.insert(meta_table, {:meta, [], -1, auth_dir})

    state = %State{
      auth_dir: auth_dir,
      provider: provider,
      refresh_fn: refresh_fn,
      refresh_policy: refresh_policy,
      refresh_policy_opts: policy_opts,
      utilization_store: utilization_store,
      server_name: name,
      accounts_table: accounts_table,
      meta_table: meta_table,
      sticky_sessions_table: sticky_sessions_table
    }

    {:ok, state, {:continue, :initial_load}}
  end

  @impl true
  def handle_continue(:initial_load, state) do
    # Schedule periodic refresh check
    Process.send_after(self(), :refresh_check, @refresh_check_interval_ms)
    # Schedule periodic stats log
    Process.send_after(self(), :log_stats, 5 * 60_000)
    # Schedule periodic sticky session cleanup
    Process.send_after(self(), :cleanup_sticky_sessions, 5 * 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload, _from, %State{} = state) do
    disk_tokens = TokenStorage.load_all_tokens(state.auth_dir, state.provider)
    disk_map = Map.new(disk_tokens, fn t -> {t.email, t} end)

    {added, updated, unchanged} =
      Enum.reduce(disk_tokens, {[], [], []}, fn disk_token, {add_acc, upd_acc, unch_acc} ->
        email = disk_token.email

        case Map.get(state.accounts, email) do
          nil ->
            # New token — add to memory
            acct = create_account_state(disk_token, state.provider, state.utilization_store)
            :ets.insert(state.accounts_table, {email, acct})
            {[email | add_acc], upd_acc, unch_acc}

          existing ->
            # Check if access_token changed
            if disk_token.access_token != existing.token.access_token do
              now = DateTime.utc_now() |> DateTime.to_iso8601()

              updated = %{
                existing
                | token: disk_token,
                  cooldown_until: 0,
                  failure_count: 0,
                  last_failure_kind: nil,
                  last_error: nil,
                  last_failure_at: nil,
                  last_success_at: now,
                  last_refresh_at: now
              }

              :ets.insert(state.accounts_table, {email, updated})
              {add_acc, [email | upd_acc], unch_acc}
            else
              {add_acc, upd_acc, [email | unch_acc]}
            end
        end
      end)

    added = Enum.reverse(added)
    updated = Enum.reverse(updated)
    unchanged = Enum.reverse(unchanged)

    # Merge accounts
    new_accounts =
      Enum.reduce(added, state.accounts, fn email, acc ->
        disk_token = Map.fetch!(disk_map, email)
        acct = create_account_state(disk_token, state.provider, state.utilization_store)
        Map.put(acc, email, acct)
      end)
      |> then(fn acc ->
        Enum.reduce(updated, acc, fn email, acc ->
          disk_token = Map.fetch!(disk_map, email)
          existing = Map.fetch!(state.accounts, email)
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          updated_acct = %{
            existing
            | token: disk_token,
              cooldown_until: 0,
              failure_count: 0,
              last_failure_kind: nil,
              last_error: nil,
              last_failure_at: nil,
              last_success_at: now,
              last_refresh_at: now
          }

          Map.put(acc, email, updated_acct)
        end)
      end)

    new_order = state.account_order ++ added

    if length(added) > 0 or length(updated) > 0 do
      Logger.info(
        "Reload: added=#{inspect(added)}, updated=#{inspect(updated)}, unchanged=#{inspect(unchanged)}"
      )
    end

    sync_meta(state, new_order, state.last_used_index)

    {:reply, %{added: added, updated: updated, unchanged: unchanged},
     %State{state | accounts: new_accounts, account_order: new_order}}
  end

  @impl true
  def handle_call(:load, _from, %State{} = state) do
    tokens = TokenStorage.load_all_tokens(state.auth_dir, state.provider)

    accounts =
      tokens
      |> Enum.map(fn token ->
        {token.email, create_account_state(token, state.provider, state.utilization_store)}
      end)
      |> Map.new()

    account_order = Enum.map(tokens, & &1.email)

    Logger.info("Loaded #{map_size(accounts)} account(s) for provider #{state.provider}")

    # Sync to ETS
    :ets.delete_all_objects(state.accounts_table)
    Enum.each(accounts, fn {email, acct} -> :ets.insert(state.accounts_table, {email, acct}) end)
    sync_meta(state, account_order, -1)

    {:reply, :ok,
     %State{state | accounts: accounts, account_order: account_order, last_used_index: -1}}
  end

  @impl true
  def handle_call({:add_account, token}, _from, %State{} = state) do
    accounts = state.accounts
    account_order = state.account_order

    {accounts, account_order} =
      if Map.has_key?(accounts, token.email) do
        # Update existing account
        existing = Map.get(accounts, token.email)
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated = %{
          existing
          | token: token,
            cooldown_until: 0,
            failure_count: 0,
            last_failure_kind: nil,
            last_error: nil,
            last_failure_at: nil,
            last_success_at: now,
            last_refresh_at: now
        }

        {Map.put(accounts, token.email, updated), account_order}
      else
        # New account
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        acct =
          create_account_state(token, token.provider, state.utilization_store)
          |> Map.put(:last_success_at, now)
          |> Map.put(:last_refresh_at, now)

        {Map.put(accounts, token.email, acct), account_order ++ [token.email]}
      end

    TokenStorage.save_token(state.auth_dir, token)

    # Sync to ETS
    :ets.insert(state.accounts_table, {token.email, accounts[token.email]})
    sync_meta(state, account_order, state.last_used_index)

    {:reply, :ok, %State{state | accounts: accounts, account_order: account_order}}
  end

  @impl true
  def handle_call({:remove_account, email}, _from, %State{} = state) do
    case Map.pop(state.accounts, email) do
      {nil, _accounts} ->
        {:reply, {:error, :not_found}, state}

      {_acct, accounts} ->
        account_order = Enum.reject(state.account_order, &(&1 == email))

        adjusted_last_used_index =
          adjust_last_used_index(state.last_used_index, state.account_order, account_order)

        with :ok <- TokenStorage.delete_token(state.auth_dir, email) do
          delete_utilization_snapshot(state.utilization_store, state.provider, email)
          :ets.delete(state.accounts_table, email)
          sync_meta(state, account_order, adjusted_last_used_index)

          {:reply, :ok,
           %State{
             state
             | accounts: accounts,
               account_order: account_order,
               last_used_index: adjusted_last_used_index
           }}
        else
          {:error, :not_found} ->
            delete_utilization_snapshot(state.utilization_store, state.provider, email)
            :ets.delete(state.accounts_table, email)
            sync_meta(state, account_order, adjusted_last_used_index)

            {:reply, :ok,
             %State{
               state
               | accounts: accounts,
                 account_order: account_order,
                 last_used_index: adjusted_last_used_index
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:refresh_account, email}, _from, %State{} = state) do
    case Map.get(state.accounts, email) do
      nil ->
        {:reply, false, state}

      acct ->
        if acct.refreshing do
          {:reply, false, state}
        else
          # Mark as refreshing
          updated_acct = %{acct | refreshing: true}
          accounts = Map.put(state.accounts, email, updated_acct)

          # Sync to ETS
          :ets.insert(state.accounts_table, {email, updated_acct})

          # Do the refresh asynchronously
          auth_dir = state.auth_dir
          refresh_token = acct.token.refresh_token
          server_name = state.server_name
          refresh_fn = state.refresh_fn

          if is_nil(refresh_fn) do
            Logger.warning("Cannot refresh account #{email}: no refresh_fn configured")
            updated_acct = %{acct | refreshing: false}
            accounts = Map.put(state.accounts, email, updated_acct)
            :ets.insert(state.accounts_table, {email, updated_acct})
            {:reply, false, %State{state | accounts: accounts}}
          else
            Task.start(fn ->
              result = refresh_fn.(refresh_token)

              case result do
                {:ok, new_token} ->
                  new_token = %{new_token | email: new_token.email || email}
                  TokenStorage.save_token(auth_dir, new_token)
                  now = DateTime.utc_now() |> DateTime.to_iso8601()
                  GenServer.cast(server_name, {:refresh_complete, email, {:ok, new_token, now}})

                {:error, reason} ->
                  GenServer.cast(server_name, {:refresh_complete, email, {:error, reason}})
              end
            end)

            {:reply, true, %State{state | accounts: accounts}}
          end
        end
    end
  end

  @impl true
  def handle_call({:bind_sticky_session, session_key, email}, _from, %State{} = state) do
    now = System.system_time(:millisecond)

    case :ets.lookup(state.sticky_sessions_table, session_key) do
      [{^session_key, _existing_email, _ttl}] ->
        case :ets.lookup(state.accounts_table, email) do
          [{^email, _new_acct}] ->
            :ets.insert(
              state.sticky_sessions_table,
              {session_key, email, now + @sticky_session_ttl_ms}
            )

          _ ->
            :ok
        end

      [] ->
        :ets.insert(
          state.sticky_sessions_table,
          {session_key, email, now + @sticky_session_ttl_ms}
        )
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear_sticky_session, session_key}, _from, %State{} = state) do
    :ets.delete(state.sticky_sessions_table, session_key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record_attempt, email}, %State{} = state) do
    case Map.get(state.accounts, email) do
      nil ->
        {:noreply, state}

      acct ->
        updated = %{acct | total_requests: acct.total_requests + 1}
        accounts = Map.put(state.accounts, email, updated)
        :ets.insert(state.accounts_table, {email, updated})
        {:noreply, %State{state | accounts: accounts}}
    end
  end

  @impl true
  def handle_cast({:record_success, email, usage, opts}, %State{} = state) do
    case Map.get(state.accounts, email) do
      nil ->
        {:noreply, state}

      acct ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated = %{
          acct
          | cooldown_until: 0,
            failure_count: 0,
            last_failure_kind: nil,
            last_error: nil,
            last_failure_at: nil,
            last_success_at: now,
            total_successes: acct.total_successes + 1,
            total_input_tokens: acct.total_input_tokens + usage_value(usage, :input_tokens),
            total_output_tokens: acct.total_output_tokens + usage_value(usage, :output_tokens),
            total_cache_creation_input_tokens:
              acct.total_cache_creation_input_tokens +
                usage_value(usage, :cache_creation_input_tokens),
            total_cache_read_input_tokens:
              acct.total_cache_read_input_tokens + usage_value(usage, :cache_read_input_tokens),
            total_reasoning_output_tokens:
              acct.total_reasoning_output_tokens + usage_value(usage, :reasoning_output_tokens)
        }

        accounts = Map.put(state.accounts, email, updated)
        :ets.insert(state.accounts_table, {email, updated})
        record_usage_stats(email, usage, opts)
        {:noreply, %State{state | accounts: accounts}}
    end
  end

  @impl true
  def handle_cast({:record_failure, email, kind, detail}, %State{} = state) do
    case Map.get(state.accounts, email) do
      nil ->
        {:noreply, state}

      acct ->
        now = System.system_time(:millisecond)
        now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
        backoff = Map.get(@failure_backoff, kind, %{base_ms: 5_000, max_ms: 300_000})

        cooldown_ms =
          min(
            (backoff.base_ms * :math.pow(2, max(0, acct.failure_count))) |> round(),
            backoff.max_ms
          )

        Logger.info("Account #{email} cooled down for #{div(cooldown_ms, 1000)}s (#{kind})")

        updated = %{
          acct
          | failure_count: acct.failure_count + 1,
            total_failures: acct.total_failures + 1,
            last_failure_kind: kind,
            last_failure_at: now_iso,
            last_error: if(detail, do: "#{kind}: #{detail}", else: "#{kind}"),
            cooldown_until: now + cooldown_ms
        }

        accounts = Map.put(state.accounts, email, updated)
        :ets.insert(state.accounts_table, {email, updated})
        {:noreply, %State{state | accounts: accounts}}
    end
  end

  @impl true
  def handle_cast({:record_utilization, email, util_info}, %State{} = state) do
    case Map.get(state.accounts, email) do
      nil ->
        {:noreply, state}

      acct ->
        provider = acct.provider || acct.token.provider || state.provider
        normalized = normalize_util_info(util_info, provider)

        updated = %{
          acct
          | utilization_5h: Map.get(normalized, :utilization_5h) || acct.utilization_5h,
            reset_5h: Map.get(normalized, :reset_5h) || acct.reset_5h,
            utilization_7d: Map.get(normalized, :utilization_7d) || acct.utilization_7d,
            reset_7d: Map.get(normalized, :reset_7d) || acct.reset_7d
        }

        accounts = Map.put(state.accounts, email, updated)
        :ets.insert(state.accounts_table, {email, updated})
        persist_utilization_snapshot(state.utilization_store, provider, email, updated)
        {:noreply, %State{state | accounts: accounts}}
    end
  end

  @impl true
  def handle_cast({:refresh_complete, email, {:ok, new_token, now}}, %State{} = state) do
    case Map.get(state.accounts, email) do
      nil ->
        {:noreply, state}

      acct ->
        updated = %{
          acct
          | token: new_token,
            refreshing: false,
            cooldown_until: 0,
            failure_count: 0,
            last_failure_kind: nil,
            last_error: nil,
            last_failure_at: nil,
            last_success_at: now,
            last_refresh_at: now
        }

        Logger.info("Token refreshed for #{email}, expires #{new_token.expires_at}")
        accounts = Map.put(state.accounts, email, updated)
        :ets.insert(state.accounts_table, {email, updated})
        {:noreply, %State{state | accounts: accounts}}
    end
  end

  @impl true
  def handle_cast({:refresh_complete, email, {:error, reason}}, %State{} = state) do
    case Map.get(state.accounts, email) do
      nil ->
        {:noreply, state}

      acct ->
        Logger.error("Token refresh failed for #{email}: #{reason}")
        now = System.system_time(:millisecond)
        now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
        backoff = @failure_backoff.auth

        cooldown_ms =
          min(
            (backoff.base_ms * :math.pow(2, max(0, acct.failure_count))) |> round(),
            backoff.max_ms
          )

        updated = %{
          acct
          | refreshing: false,
            failure_count: acct.failure_count + 1,
            total_failures: acct.total_failures + 1,
            last_failure_kind: :auth,
            last_failure_at: now_iso,
            last_error: "auth: #{reason}",
            cooldown_until: now + cooldown_ms
        }

        accounts = Map.put(state.accounts, email, updated)
        :ets.insert(state.accounts_table, {email, updated})
        {:noreply, %State{state | accounts: accounts}}
    end
  end

  @impl true
  def handle_cast({:update_round_robin, idx}, %State{} = state) do
    sync_meta(state, state.account_order, idx)
    {:noreply, %State{state | last_used_index: idx}}
  end

  @impl true
  def handle_cast({:bind_sticky_session, session_key, email}, %State{} = state) do
    now = System.system_time(:millisecond)

    case :ets.lookup(state.sticky_sessions_table, session_key) do
      [{^session_key, _existing_email, _ttl}] ->
        case :ets.lookup(state.accounts_table, email) do
          [{^email, _new_acct}] ->
            :ets.insert(
              state.sticky_sessions_table,
              {session_key, email, now + @sticky_session_ttl_ms}
            )

          _ ->
            :ok
        end

      [] ->
        :ets.insert(
          state.sticky_sessions_table,
          {session_key, email, now + @sticky_session_ttl_ms}
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:refresh_sticky_session, session_key}, %State{} = state) do
    now = System.system_time(:millisecond)

    case :ets.lookup(state.sticky_sessions_table, session_key) do
      [{^session_key, email, _ttl}] ->
        :ets.insert(
          state.sticky_sessions_table,
          {session_key, email, now + @sticky_session_ttl_ms}
        )

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear_sticky_session, session_key}, %State{} = state) do
    :ets.delete(state.sticky_sessions_table, session_key)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_check, %State{} = state) do
    now = System.system_time(:millisecond)

    Enum.each(state.accounts, fn {_email, acct} ->
      expires_at =
        case DateTime.from_iso8601(acct.token.expires_at) do
          {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
          _ -> 0
        end

      if expires_at - now <= @refresh_lead_ms and not acct.refreshing do
        refresh_account(state.server_name, acct.token.email)
      end
    end)

    Process.send_after(self(), :refresh_check, @refresh_check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:log_stats, %State{} = state) do
    if map_size(state.accounts) > 0 do
      now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
      Logger.info("\n===== Account Stats (#{now_iso}) =====")

      Enum.each(state.accounts, fn {_email, acct} ->
        available = acct.cooldown_until <= System.system_time(:millisecond)

        Logger.info(
          "  #{acct.token.email}: " <>
            "available=#{available}, " <>
            "requests=#{acct.total_requests}, " <>
            "successes=#{acct.total_successes}, " <>
            "failures=#{acct.total_failures}, " <>
            "input_tokens=#{acct.total_input_tokens}, " <>
            "output_tokens=#{acct.total_output_tokens}, " <>
            "cache_creation=#{acct.total_cache_creation_input_tokens}, " <>
            "cache_read=#{acct.total_cache_read_input_tokens}, " <>
            "total_tokens=#{acct.total_input_tokens + acct.total_output_tokens + acct.total_cache_creation_input_tokens + acct.total_cache_read_input_tokens}"
        )
      end)

      Logger.info("====================================================\n")
    end

    Process.send_after(self(), :log_stats, 5 * 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_sticky_sessions, %State{} = state) do
    now = System.system_time(:millisecond)
    match_spec = [{{:"$1", :_, :"$2"}, [{:<, :"$2", {:const, now}}], [true]}]
    :ets.select_delete(state.sticky_sessions_table, match_spec)
    Process.send_after(self(), :cleanup_sticky_sessions, 5 * 60_000)
    {:noreply, state}
  end

  # ── Private helpers ──

  defp sync_meta(state, account_order, last_used_index) do
    :ets.insert(state.meta_table, {:meta, account_order, last_used_index, state.auth_dir})
  end

  defp usage_value(nil, _key), do: 0
  defp usage_value(usage, key) when is_map(usage), do: Map.get(usage, key, 0) || 0

  defp record_usage_stats(email, usage, opts) do
    model = Keyword.get(opts, :model)
    provider = Keyword.get(opts, :provider)
    server = Keyword.get(opts, :usage_stats_server, UsageStats)

    if is_binary(model) and String.trim(model) != "" and is_binary(provider) and
         String.trim(provider) != "" and usage_stats_alive?(server) do
      UsageStats.record(server, provider, email, model, usage || %{})
    end
  rescue
    error ->
      Logger.warning("UsageStats record failed: #{Exception.message(error)}")
      :ok
  end

  defp usage_stats_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp usage_stats_alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp usage_stats_alive?(_), do: false

  defp restore_utilization_snapshot(%AccountState{} = acct, store, provider, email) do
    case utilization_store_get(store, provider, email) do
      nil ->
        acct

      snapshot ->
        %{
          acct
          | utilization_5h: Map.get(snapshot, :utilization_5h),
            reset_5h: Map.get(snapshot, :reset_5h),
            utilization_7d: Map.get(snapshot, :utilization_7d),
            reset_7d: Map.get(snapshot, :reset_7d)
        }
    end
  end

  defp persist_utilization_snapshot(store, provider, email, %AccountState{} = acct) do
    snapshot = %{
      utilization_5h: acct.utilization_5h,
      reset_5h: acct.reset_5h,
      utilization_7d: acct.utilization_7d,
      reset_7d: acct.reset_7d,
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      source: "#{provider}_headers"
    }

    utilization_store_put(store, provider, email, snapshot)
  end

  defp delete_utilization_snapshot(store, provider, email) do
    utilization_store_delete(store, provider, email)
  end

  defp normalize_util_info(util_info, provider) do
    %{
      utilization_5h:
        normalize_ingested_utilization(Map.get(util_info, :utilization_5h), provider),
      reset_5h: normalize_reset(Map.get(util_info, :reset_5h)),
      utilization_7d:
        normalize_ingested_utilization(Map.get(util_info, :utilization_7d), provider),
      reset_7d: normalize_reset(Map.get(util_info, :reset_7d))
    }
  end

  defp normalize_ingested_utilization(nil, _provider), do: nil

  defp normalize_ingested_utilization(value, "anthropic") when is_number(value) do
    if value <= 1.0, do: value * 100, else: value * 1.0
  end

  defp normalize_ingested_utilization(value, _provider) when is_number(value), do: value * 1.0
  defp normalize_ingested_utilization(_value, _provider), do: nil

  defp normalize_reset(reset) when is_binary(reset) and reset != "", do: reset
  defp normalize_reset(_), do: nil

  defp utilization_store_get(store, provider, email) do
    if utilization_store_alive?(store) do
      UtilizationStore.get(store, provider, email)
    end
  rescue
    error ->
      Logger.warning("UtilizationStore get failed: #{Exception.message(error)}")
      nil
  end

  defp utilization_store_put(store, provider, email, snapshot) do
    if utilization_store_alive?(store) do
      UtilizationStore.put(store, provider, email, snapshot)
    end

    :ok
  rescue
    error ->
      Logger.warning("UtilizationStore put failed: #{Exception.message(error)}")
      :ok
  end

  defp utilization_store_delete(store, provider, email) do
    if utilization_store_alive?(store) do
      UtilizationStore.delete(store, provider, email)
    end

    :ok
  rescue
    error ->
      Logger.warning("UtilizationStore delete failed: #{Exception.message(error)}")
      :ok
  end

  defp utilization_store_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp utilization_store_alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp utilization_store_alive?(_), do: false

  defp build_available_account(auth_dir, email, token) do
    %AvailableAccount{
      token: token,
      provider: token.provider,
      device_id: Common.get_device_id(auth_dir, email),
      account_uuid: token.account_uuid,
      chatgpt_account_id: Map.get(token, :chatgpt_account_id)
    }
  end

  defp create_account_state(token, provider, utilization_store) do
    %AccountState{token: token, provider: provider}
    |> restore_utilization_snapshot(utilization_store, provider, token.email)
  end

  defp adjust_last_used_index(-1, _previous_order, _new_order), do: -1

  defp adjust_last_used_index(last_used_index, previous_order, new_order) do
    case Enum.at(previous_order, last_used_index) do
      nil -> -1
      email -> Enum.find_index(new_order, &(&1 == email)) || -1
    end
  end
end
