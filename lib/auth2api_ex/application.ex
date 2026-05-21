defmodule Auth2ApiEx.Application do
  @moduledoc """
  OTP Application module for auth2api_ex.
  Starts the supervision tree with AccountManager and HTTP server.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Initialize ETS tables
    :ets.new(:auth2api_ex_sessions, [:set, :public, :named_table])
    :ets.new(:auth2api_ex_rate_limit, [:set, :public, :named_table])

    # Load configuration — CLI --config flag takes priority over env var
    config_path =
      Application.get_env(:auth2api_ex, :config_path) ||
        System.get_env("AUTH2API_CONFIG") ||
        "config.yaml"

    config = Auth2ApiEx.Config.load_config(config_path)
    Application.put_env(:auth2api_ex, :config, config)

    auth_dir = Auth2ApiEx.Config.resolve_auth_dir(config.auth_dir)

    host = if config.host == "", do: "127.0.0.1", else: config.host
    port = config.port

    usage_stats_dir = Path.join(auth_dir, "usage_stats")

    children = [
      {Auth2ApiEx.AuditLog, []},
      {Auth2ApiEx.UsageStats, [dir: usage_stats_dir]},
      {Auth2ApiEx.Accounts.UtilizationStore, [dir: usage_stats_dir]}
    ]

    opts = [strategy: :one_for_one, name: Auth2ApiEx.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Build provider registry after persistent stores are available so
        # AccountManagers can restore utilization snapshots during load.
        registry = Auth2ApiEx.Providers.Registry.build(auth_dir)
        Application.put_env(:auth2api_ex, :registry, registry)
        Application.put_env(:auth2api_ex, :manager_name, :anthropic_manager)
        Application.put_env(:auth2api_ex, :started_at, DateTime.utc_now())
        Application.put_env(:auth2api_ex, :auth_dir, auth_dir)
        Application.put_env(:auth2api_ex, :config_path, config_path)

        # Schedule periodic cleanup
        schedule_rate_limit_cleanup()
        schedule_session_cleanup()

        if Application.get_env(:auth2api_ex, :start_http_server, true) do
          {:ok, _} =
            Supervisor.start_child(Auth2ApiEx.Supervisor, {
              Plug.Cowboy,
              scheme: :http, plug: Auth2ApiEx.Server, options: [ip: parse_ip(host), port: port]
            })
        end

        Logger.info("auth2api_ex server started on http://#{host}:#{port}")
        Logger.info("Visit http://#{host}:#{port}/admin to manage config and add accounts")

        {:ok, pid}

      error ->
        error
    end
  end

  defp parse_ip("127.0.0.1"), do: {127, 0, 0, 1}
  defp parse_ip("0.0.0.0"), do: {0, 0, 0, 0}
  defp parse_ip("localhost"), do: {127, 0, 0, 1}

  defp parse_ip(ip_str),
    do: ip_str |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

  defp schedule_rate_limit_cleanup do
    spawn(fn ->
      Process.sleep(5 * 60_000)
      cleanup_rate_limits()
      schedule_rate_limit_cleanup()
    end)
  end

  # 30 minutes, matching Go version
  @session_ttl_seconds 30 * 60

  defp schedule_session_cleanup do
    spawn(fn ->
      Process.sleep(5 * 60_000)
      cleanup_sessions()
      schedule_session_cleanup()
    end)
  end

  defp cleanup_sessions do
    now = System.system_time(:second)

    :ets.foldl(
      fn
        {session_id, %{created_at: created_at}}, acc ->
          if now - created_at > @session_ttl_seconds do
            :ets.delete(:auth2api_ex_sessions, session_id)
          end

          acc

        _, acc ->
          acc
      end,
      :ok,
      :auth2api_ex_sessions
    )
  end

  defp cleanup_rate_limits do
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {ip, _count, reset_at}, acc ->
        if now > reset_at do
          :ets.delete(:auth2api_ex_rate_limit, ip)
        end

        acc
      end,
      :ok,
      :auth2api_ex_rate_limit
    )
  end
end
