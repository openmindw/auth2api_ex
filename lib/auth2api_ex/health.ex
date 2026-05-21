defmodule Auth2ApiEx.Health do
  @moduledoc """
  Health check endpoint logic — queries account managers via ETS for
  account availability, token expiry, and cache usage summaries.

  Two levels of detail:
    - `check_public/1` — unauthenticated, no per-account data (no emails, errors, plan types)
    - `check_full/1`   — admin-authenticated, full per-account report
  """

  alias Auth2ApiEx.Accounts.Manager

  @max_error_len 100

  @doc """
  Public (unauthenticated) health check — summary only, no PII.

  Returns: status, uptime, total/available counts, per-provider aggregated counts,
  per-provider token expired_count, and an anonymized degraded account count.
  """
  @spec check_public(map()) :: map()
  def check_public(registry) do
    now_ms = System.system_time(:millisecond)
    now_iso = DateTime.utc_now()
    started_at = Application.get_env(:auth2api_ex, :started_at)
    uptime = if started_at, do: DateTime.diff(now_iso, started_at), else: 0

    providers =
      Enum.map(registry.providers, fn provider ->
        provider_public(provider, now_ms)
      end)

    total_accts = Enum.reduce(providers, 0, &(&1.total_accounts + &2))
    total_avail = Enum.reduce(providers, 0, &(&1.available_accounts + &2))
    status = if total_accts > 0 and total_avail == 0, do: "degraded", else: "ok"

    %{
      status: status,
      uptime_seconds: uptime,
      total_accounts: total_accts,
      available_accounts: total_avail,
      providers: providers
    }
  end

  @doc """
  Admin-authenticated full health check — includes per-account details
  and a cache usage summary.
  """
  @spec check_full(map()) :: map()
  def check_full(registry) do
    now_ms = System.system_time(:millisecond)
    now_iso = DateTime.utc_now()
    started_at = Application.get_env(:auth2api_ex, :started_at)
    uptime = if started_at, do: DateTime.diff(now_iso, started_at), else: 0

    providers =
      Enum.map(registry.providers, fn provider ->
        provider_full(provider, now_ms)
      end)

    total_accts = Enum.reduce(providers, 0, &(&1.total_accounts + &2))
    total_avail = Enum.reduce(providers, 0, &(&1.available_accounts + &2))
    status = if total_accts > 0 and total_avail == 0, do: "degraded", else: "ok"

    %{
      status: status,
      uptime_seconds: uptime,
      total_accounts: total_accts,
      available_accounts: total_avail,
      providers: providers,
      cache_usage_summary: build_cache_usage_summary(registry.providers, now_ms)
    }
  end

  # ── Public (anonymized) per-provider ──

  defp provider_public(provider, now_ms) do
    snapshots = Manager.get_snapshots(provider.manager)
    total = length(snapshots)
    available = Enum.count(snapshots, fn s -> s.available end)
    {_earliest, _latest, expired_count} = token_expiry_info(snapshots, now_ms)
    degraded_count = total - available

    %{
      provider: to_string(provider.id),
      total_accounts: total,
      available_accounts: available,
      degraded_accounts: degraded_count,
      token_expired_count: expired_count
    }
  end

  # ── Full (admin-authenticated) per-provider ──

  defp provider_full(provider, now_ms) do
    snapshots = Manager.get_snapshots(provider.manager)
    total = length(snapshots)
    available = Enum.count(snapshots, fn s -> s.available end)
    {earliest_expiry, latest_expiry, expired_count} = token_expiry_info(snapshots, now_ms)

    cooldown_accounts =
      Enum.filter(snapshots, fn s -> not s.available end)
      |> Enum.map(fn s ->
        remaining_ms = max(0, s.cooldown_until - now_ms)
        remaining_s = div(remaining_ms, 1000)

        %{
          email: s.email,
          failure_kind: s.last_failure_kind,
          cooldown_remaining_seconds: remaining_s,
          last_error: truncate_error(s.last_error)
        }
      end)

    cache_keys =
      snapshots
      |> Enum.filter(fn s -> s.available end)
      |> Enum.map(fn s ->
        expires_at_ms = parse_expires_at_ms(s.expires_at)

        remaining_s =
          if expires_at_ms > 0, do: div(max(0, expires_at_ms - now_ms), 1000), else: nil

        %{
          email: s.email,
          plan_type: s.plan_type,
          expires_at: s.expires_at,
          token_remaining_seconds: remaining_s,
          total_cache_creation_input_tokens: s.total_cache_creation_input_tokens,
          total_cache_read_input_tokens: s.total_cache_read_input_tokens
        }
      end)

    %{
      provider: to_string(provider.id),
      total_accounts: total,
      available_accounts: available,
      token_expiry: %{
        earliest_expires_at: earliest_expiry,
        latest_expires_at: latest_expiry,
        expired_count: expired_count
      },
      cooldown_accounts: cooldown_accounts,
      prompt_cache_keys: cache_keys
    }
  end

  # ── Shared helpers ──

  defp token_expiry_info(snapshots, now_ms) do
    # Pre-compute parsed expiry timestamps to avoid repeated parsing
    parsed =
      Enum.map(snapshots, fn s ->
        {s.expires_at, parse_expires_at_ms(s.expires_at)}
      end)

    {earliest, latest, expired} =
      Enum.reduce(parsed, {nil, nil, 0}, fn {expires_str, expires_ms},
                                            {earliest, latest, expired} ->
        earliest =
          cond do
            is_nil(earliest) -> expires_str
            expires_ms < parse_expires_at_ms(earliest) -> expires_str
            true -> earliest
          end

        latest =
          cond do
            is_nil(latest) -> expires_str
            expires_ms > parse_expires_at_ms(latest) -> expires_str
            true -> latest
          end

        expired =
          if expires_ms > 0 and expires_ms <= now_ms do
            expired + 1
          else
            expired
          end

        {earliest, latest, expired}
      end)

    {earliest, latest, expired}
  end

  defp parse_expires_at_ms(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp parse_expires_at_ms(_), do: 0

  defp truncate_error(nil), do: nil

  defp truncate_error(error) when is_binary(error) do
    if byte_size(error) > @max_error_len do
      String.slice(error, 0, @max_error_len) <> "..."
    else
      error
    end
  end

  defp build_cache_usage_summary(provider_list, now_ms) do
    all_cache_accounts =
      Enum.flat_map(provider_list, fn provider ->
        snapshots = Manager.get_snapshots(provider.manager)

        snapshots
        |> Enum.filter(fn s -> s.available end)
        |> Enum.map(fn s ->
          expires_at_ms = parse_expires_at_ms(s.expires_at)

          remaining_s =
            if expires_at_ms > 0, do: div(max(0, expires_at_ms - now_ms), 1000), else: nil

          %{
            provider: to_string(provider.id),
            email: s.email,
            plan_type: s.plan_type,
            token_remaining_seconds: remaining_s,
            cache_creation_tokens: s.total_cache_creation_input_tokens,
            cache_read_tokens: s.total_cache_read_input_tokens
          }
        end)
      end)

    %{
      description: "Per-account prompt cache usage statistics.",
      accounts: all_cache_accounts
    }
  end
end
