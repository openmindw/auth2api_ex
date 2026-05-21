defmodule Auth2ApiEx.Admin.Handler do
  @moduledoc """
  BasicAuth-protected admin HTML and JSON endpoints.
  Supports multi-provider account management (Anthropic + Codex).
  """

  use Plug.Router

  alias Auth2ApiEx.{Config, Accounts.Manager, UsageStats}
  alias Auth2ApiEx.Admin.HTML
  alias Auth2ApiEx.AuditLog
  alias Auth2ApiEx.Auth.{CookieAuth, OAuth, PKCE, CodexOAuth}

  import Auth2ApiEx.PlugHelpers, only: [send_json: 3]

  plug(:fetch_admin_config)
  plug(:require_basic_auth)
  plug(:parse_body)
  plug(:match)
  plug(:dispatch)

  get "/admin" do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, HTML.render())
  end

  # ── Providers ──

  get "/admin/api/providers" do
    registry = conn.assigns[:registry]

    providers =
      Enum.map(registry.providers, fn p ->
        %{
          id: to_string(p.id),
          label: provider_label(p.id),
          account_count: Manager.account_count(p.manager)
        }
      end)

    send_json(conn, 200, %{providers: providers})
  end

  # ── Accounts ──

  get "/admin/api/accounts" do
    provider = conn.params["provider"]
    {accounts, account_count} = list_accounts(conn, provider)

    send_json(conn, 200, %{
      accounts: accounts,
      account_count: account_count,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  post "/admin/api/accounts/oauth-start" do
    provider = get_provider_from_body(conn)
    session_id = UUID.uuid4()
    state = UUID.uuid4()
    pkce = PKCE.generate_pkce_codes()

    auth_url =
      if provider == "codex" do
        CodexOAuth.generate_auth_url(state, pkce)
      else
        OAuth.generate_auth_url(state, pkce)
      end

    :ets.insert(
      :auth2api_ex_sessions,
      {session_id,
       %{state: state, pkce: pkce, provider: provider, created_at: System.system_time(:second)}}
    )

    send_json(conn, 200, %{session_id: session_id, auth_url: auth_url})
  end

  post "/admin/api/accounts/oauth-exchange" do
    body = conn.assigns[:parsed_body] || %{}
    session_id = body["session_id"] || ""
    code = body["code"] || ""

    cond do
      session_id == "" or code == "" ->
        send_json(conn, 400, %{error: "session_id and code are required"})

      true ->
        case :ets.lookup(:auth2api_ex_sessions, session_id) do
          [{^session_id, %{state: state, pkce: pkce} = session}] ->
            :ets.delete(:auth2api_ex_sessions, session_id)
            provider = Map.get(session, :provider, "anthropic")
            manager = get_manager_by_provider(conn, provider)

            exchange_result =
              if provider == "codex" do
                CodexOAuth.exchange_code(code, state, state, pkce)
              else
                OAuth.exchange_code_for_tokens(code, state, state, pkce)
              end

            case exchange_result do
              {:ok, token} ->
                token = %{token | provider: provider}
                :ok = Manager.add_account(manager, token)
                send_json(conn, 200, %{email: token.email, expires_at: token.expires_at})

              {:error, reason} ->
                send_json(conn, 400, %{error: reason})
            end

          [] ->
            send_json(conn, 404, %{error: "OAuth session not found or expired"})
        end
    end
  end

  post "/admin/api/accounts/cookie-auth" do
    provider = get_provider_from_body(conn)

    if provider == "codex" do
      send_json(conn, 400, %{
        error: "cookie-auth is not supported for Codex provider. Use OAuth instead."
      })
    else
      session_key =
        get_in(conn.assigns[:parsed_body], ["session_key"]) ||
          get_in(conn.assigns[:parsed_body], [:session_key])

      case is_binary(session_key) && String.trim(session_key) do
        trimmed when is_binary(trimmed) and byte_size(trimmed) > 0 ->
          case CookieAuth.authorize(trimmed) do
            {:ok, token} ->
              manager = get_manager(conn)
              :ok = Manager.add_account(manager, token)
              send_json(conn, 200, %{email: token.email, expires_at: token.expires_at})

            {:error, reason} ->
              send_json(conn, 400, %{error: reason})
          end

        _ ->
          send_json(conn, 400, %{error: "session_key is required"})
      end
    end
  end

  post "/admin/api/accounts/:email/refresh" do
    manager = get_manager(conn)
    email = URI.decode(email)
    snapshots = Manager.get_snapshots(manager)

    cond do
      Enum.any?(snapshots, &(&1.email == email and &1.refreshing)) ->
        send_json(conn, 409, %{error: "Account refresh already in progress"})

      Enum.any?(snapshots, &(&1.email == email)) and Manager.refresh_account(manager, email) ->
        send_json(conn, 202, %{status: "refreshing"})

      true ->
        send_json(conn, 404, %{error: "Account not found"})
    end
  end

  delete "/admin/api/accounts/:email" do
    manager = get_manager(conn)

    case Manager.remove_account(manager, URI.decode(email)) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "Account not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/admin/api/keys" do
    config = conn.assigns[:config]

    keys =
      config.api_keys
      |> Enum.sort()
      |> Enum.map(fn key -> %{key: key, masked: mask_key(key)} end)

    send_json(conn, 200, %{keys: keys})
  end

  get "/admin/api/usage" do
    totals = safe_usage_totals()
    daily = safe_usage_daily()

    send_json(conn, 200, %{
      summary: usage_summary(totals, daily),
      totals: Enum.map(totals, &format_usage_total/1),
      daily: Enum.map(daily, &format_usage_daily/1),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  post "/admin/api/keys" do
    body = conn.assigns[:parsed_body] || %{}
    custom_key = Map.get(body, "key") || Map.get(body, "custom_key")

    custom_key =
      case custom_key do
        val when is_binary(val) ->
          trimmed = String.trim(val)
          if trimmed != "", do: trimmed, else: nil

        _ ->
          nil
      end

    config = conn.assigns[:config]

    cond do
      custom_key && MapSet.member?(config.api_keys, custom_key) ->
        send_json(conn, 400, %{error: "API 密钥已存在"})

      true ->
        key = custom_key || Config.generate_api_key()

        case Config.add_api_key(conn.assigns[:config_path], key) do
          {:ok, updated_config} ->
            Application.put_env(:auth2api_ex, :config, updated_config)
            send_json(conn, 201, %{key: key, masked: mask_key(key)})

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  delete "/admin/api/keys/:key" do
    case Config.remove_api_key(conn.assigns[:config_path], URI.decode(key)) do
      {:ok, updated_config} ->
        Application.put_env(:auth2api_ex, :config, updated_config)
        send_json(conn, 200, %{status: "deleted"})

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "API key not found"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/admin/api/reload" do
    manager = get_manager(conn)
    result = Manager.reload(manager)

    send_json(conn, 200, %{
      reload: result,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # ── Version ──

  get "/admin/api/version" do
    send_json(conn, 200, Auth2ApiEx.Version.info())
  end

  # ── Audit Log ──

  get "/admin/api/logs" do
    limit = parse_int_param(conn.params["limit"], 100)
    offset = parse_int_param(conn.params["offset"], 0)
    status_filter = parse_status_filter(conn.params["status"])

    logs = AuditLog.list(limit: limit, offset: offset, status: status_filter)

    send_json(conn, 200, %{
      logs: Enum.map(logs, &format_audit_log/1),
      total: AuditLog.count()
    })
  end

  delete "/admin/api/logs" do
    AuditLog.clear()
    send_json(conn, 200, %{status: "cleared"})
  end

  match _ do
    send_json(conn, 404, %{error: "Not found"})
  end

  # ── Private helpers ──

  defp fetch_admin_config(conn, _opts) do
    config = Application.get_env(:auth2api_ex, :config)
    config_path = Application.get_env(:auth2api_ex, :config_path) || "config.yaml"
    registry = Application.get_env(:auth2api_ex, :registry)

    conn
    |> Plug.Conn.assign(:config, config)
    |> Plug.Conn.assign(:config_path, config_path)
    |> Plug.Conn.assign(:registry, registry)
  end

  defp get_manager(conn) do
    provider = get_provider_from_query(conn)
    get_manager_by_provider(conn, provider)
  end

  defp list_accounts(conn, nil) do
    registry = conn.assigns[:registry]

    if registry && registry.providers do
      accounts =
        registry.providers
        |> Enum.flat_map(fn provider ->
          provider.manager |> Manager.get_snapshots() |> Enum.map(&format_account/1)
        end)
        |> Enum.sort_by(&{Map.get(&1, :provider, "anthropic"), &1.email})

      account_count =
        Enum.reduce(registry.providers, 0, fn provider, acc ->
          acc + Manager.account_count(provider.manager)
        end)

      {accounts, account_count}
    else
      manager = get_manager(conn)
      accounts = manager |> Manager.get_snapshots() |> Enum.map(&format_account/1)
      {accounts, Manager.account_count(manager)}
    end
  end

  defp list_accounts(conn, provider) do
    manager = get_manager_by_provider(conn, provider)
    accounts = manager |> Manager.get_snapshots() |> Enum.map(&format_account/1)
    {accounts, Manager.account_count(manager)}
  end

  defp get_manager_by_provider(conn, provider) do
    registry = conn.assigns[:registry]

    if registry && registry.by_id do
      # Safe atom conversion: only allow known provider atoms to prevent atom exhaustion
      provider_atom =
        case provider do
          "anthropic" -> :anthropic
          "codex" -> :codex
          _ -> :anthropic
        end

      case Map.get(registry.by_id, provider_atom) do
        %{manager: mgr} -> mgr
        nil -> registry.by_id.anthropic.manager
      end
    else
      Application.get_env(:auth2api_ex, :manager_name, Manager)
    end
  end

  defp get_provider_from_query(conn) do
    conn.params["provider"] || "anthropic"
  end

  defp get_provider_from_body(conn) do
    body = conn.assigns[:parsed_body] || %{}
    Map.get(body, "provider") || Map.get(body, :provider) || "anthropic"
  end

  defp provider_label(:anthropic), do: "Anthropic"
  defp provider_label(:codex), do: "Codex"
  defp provider_label(other), do: to_string(other)

  defp safe_usage_totals do
    if Process.whereis(UsageStats), do: UsageStats.totals(), else: []
  rescue
    _ -> []
  end

  defp safe_usage_daily do
    if Process.whereis(UsageStats), do: UsageStats.daily(), else: []
  rescue
    _ -> []
  end

  defp usage_summary(totals, daily) do
    total_tokens = Enum.reduce(totals, 0, &(&2 + row_total_tokens(&1)))
    cache_read = Enum.reduce(totals, 0, &(&2 + Map.get(&1, :cache_read_input_tokens, 0)))
    input_tokens = Enum.reduce(totals, 0, &(&2 + Map.get(&1, :input_tokens, 0)))
    requests = Enum.reduce(totals, 0, &(&2 + Map.get(&1, :requests, 0)))
    today = Date.utc_today()

    today_tokens =
      daily
      |> Enum.filter(&(Map.get(&1, :date) == today))
      |> Enum.reduce(0, &(&2 + row_total_tokens(&1)))

    %{
      requests: requests,
      total_tokens: total_tokens,
      today_tokens: today_tokens,
      cache_read_tokens: cache_read,
      cache_hit_ratio: ratio(cache_read, input_tokens),
      model_count:
        totals
        |> Enum.map(&Map.get(&1, :model))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length(),
      provider_breakdown: provider_breakdown(totals)
    }
  end

  defp format_usage_total(row) do
    row
    |> Map.take([
      :provider,
      :email,
      :model,
      :requests,
      :input_tokens,
      :output_tokens,
      :cache_creation_input_tokens,
      :cache_creation_5m_tokens,
      :cache_creation_1h_tokens,
      :cache_read_input_tokens,
      :reasoning_output_tokens,
      :last_at
    ])
    |> Map.put(:total_tokens, row_total_tokens(row))
  end

  defp format_usage_daily(row) do
    row
    |> Map.take([
      :provider,
      :email,
      :model,
      :requests,
      :input_tokens,
      :output_tokens,
      :cache_creation_input_tokens,
      :cache_creation_5m_tokens,
      :cache_creation_1h_tokens,
      :cache_read_input_tokens,
      :reasoning_output_tokens
    ])
    |> Map.put(:date, row.date |> Date.to_iso8601())
    |> Map.put(:total_tokens, row_total_tokens(row))
  end

  defp provider_breakdown(totals) do
    ["anthropic", "codex"]
    |> Enum.map(fn provider ->
      rows = Enum.filter(totals, &(Map.get(&1, :provider) == provider))
      input_tokens = Enum.reduce(rows, 0, &(&2 + Map.get(&1, :input_tokens, 0)))
      cache_read = Enum.reduce(rows, 0, &(&2 + Map.get(&1, :cache_read_input_tokens, 0)))

      {provider,
       %{
         requests: Enum.reduce(rows, 0, &(&2 + Map.get(&1, :requests, 0))),
         total_tokens: Enum.reduce(rows, 0, &(&2 + row_total_tokens(&1))),
         input_tokens: input_tokens,
         cache_read_tokens: cache_read,
         cache_hit_ratio: ratio(cache_read, input_tokens),
         model_count:
           rows
           |> Enum.map(&Map.get(&1, :model))
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> length()
       }}
    end)
    |> Enum.into(%{})
  end

  defp row_total_tokens(row) do
    Map.get(row, :input_tokens, 0) +
      Map.get(row, :output_tokens, 0)
  end

  defp ratio(_num, denom) when denom <= 0, do: 0.0
  defp ratio(num, denom), do: Float.round(num / denom, 4)

  defp require_basic_auth(conn, _opts) do
    config = conn.assigns[:config]

    with [header | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, username, password} <- parse_basic_auth_header(header),
         true <- secure_compare(username, config && config.admin_username),
         true <- secure_compare(password, config && config.admin_password) do
      conn
    else
      _ ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", "Basic realm=\"auth2api_ex-admin\"")
        |> Plug.Conn.send_resp(401, "Unauthorized")
        |> Plug.Conn.halt()
    end
  end

  defp parse_body(conn, _opts) do
    opts = [
      parsers: [{Plug.Parsers.JSON, json_decoder: Jason}],
      pass: ["application/json"],
      body_reader: {Plug.Conn, :read_body, []}
    ]

    conn = Plug.Parsers.call(conn, Plug.Parsers.init(opts))
    Plug.Conn.assign(conn, :parsed_body, conn.body_params)
  rescue
    _ ->
      conn
      |> send_json(400, %{error: "Invalid request body"})
      |> Plug.Conn.halt()
  end

  defp format_account(snapshot) do
    now = DateTime.utc_now()

    expires_dt =
      case DateTime.from_iso8601(snapshot.expires_at) do
        {:ok, dt, _offset} -> dt
        _ -> nil
      end

    {status, label} =
      cond do
        snapshot.refreshing -> {:cooldown, "refreshing"}
        snapshot.available and is_nil(snapshot.last_error) -> {:active, "active"}
        snapshot.available -> {:error, "error"}
        true -> {:cooldown, "cooldown"}
      end

    %{
      email: snapshot.email,
      provider: snapshot.provider || Map.get(snapshot, :provider) || "anthropic",
      status: status,
      status_label: label,
      expires_at: snapshot.expires_at,
      expires_in_human: humanize_expiry(expires_dt, now),
      success_count: snapshot.total_successes,
      failure_count: snapshot.total_failures,
      refreshing: snapshot.refreshing,
      last_error: snapshot.last_error,
      last_failure_kind: snapshot.last_failure_kind,
      utilization_5h: snapshot.utilization_5h,
      reset_5h: snapshot.reset_5h,
      reset_5h_human: humanize_reset(snapshot.reset_5h, now),
      utilization_7d: snapshot.utilization_7d,
      reset_7d: snapshot.reset_7d,
      reset_7d_human: humanize_reset(snapshot.reset_7d, now)
    }
  end

  defp humanize_reset(nil, _now), do: nil

  defp humanize_reset(reset_str, now) do
    case DateTime.from_iso8601(reset_str) do
      {:ok, reset_dt, _} ->
        seconds = DateTime.diff(reset_dt, now, :second)
        if seconds <= 0, do: "已重置", else: humanize_duration(seconds)

      _ ->
        nil
    end
  end

  defp humanize_duration(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3600)}h"
    end
  end

  defp humanize_expiry(nil, _now), do: "unknown"

  defp humanize_expiry(expires_dt, now) do
    seconds = DateTime.diff(expires_dt, now, :second)

    cond do
      seconds <= 0 -> "已过期"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3600)}h"
    end
  end

  defp mask_key(key) when byte_size(key) <= 10, do: key
  defp mask_key(key), do: String.slice(key, 0, 6) <> "..." <> String.slice(key, -4, 4)

  defp parse_basic_auth_header("Basic " <> encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} ->
        case String.split(decoded, ":", parts: 2) do
          [username, password] -> {:ok, username, password}
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp parse_basic_auth_header(_), do: :error

  defp secure_compare(_left, nil), do: false
  defp secure_compare(nil, _right), do: false
  defp secure_compare(left, right), do: Plug.Crypto.secure_compare(left, right)

  defp parse_int_param(nil, default), do: default

  defp parse_int_param(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_status_filter(nil), do: nil
  defp parse_status_filter("2xx"), do: :"2xx"
  defp parse_status_filter("4xx"), do: :"4xx"
  defp parse_status_filter("5xx"), do: :"5xx"
  defp parse_status_filter("all"), do: nil
  defp parse_status_filter(_), do: nil

  defp format_audit_log(log) do
    Map.take(log, [
      :id,
      :timestamp,
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
  end
end
