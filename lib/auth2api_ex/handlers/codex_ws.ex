defmodule Auth2ApiEx.Handlers.CodexWS do
  @moduledoc """
  WebSocket proxy for Codex CLI file operations.

  Upgrades the client WebSocket connection and proxies frames
  bidirectionally between Codex CLI and chatgpt.com.

  Lifecycle:
    1. Client → GET /v1/responses (Upgrade: websocket)
    2. Validate API key + get Codex account
    3. Connect upstream → wss://chatgpt.com/backend-api/codex/responses
    4. Forward frames bidirectionally
    5. Close both sides on termination
  """

  @behaviour :cowboy_websocket

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Providers.Registry
  alias Auth2ApiEx.Upstream.CodexAPI

  require Logger

  @impl true
  def init(req, state) do
    # Validate API key from query param or header
    api_key = extract_api_key(req)

    config = state.config
    registry = state.registry

    unless valid_api_key?(config, api_key) do
      Logger.warning("[codex_ws] invalid api key")
      {:ok, :cowboy_req.reply(401, %{"content-type" => "application/json"}, Jason.encode!(%{error: "Invalid API key"}), req), %{}}
    else
      # Get codex provider and account
      provider = Registry.for_model(registry, "gpt-5")
      manager = provider.manager

      case Manager.get_next_account(manager) do
        %{account: nil} = result ->
          Logger.warning("[codex_ws] no available account kind=#{inspect(result.failure_kind)}")
          {:ok, :cowboy_req.reply(503, %{}, "", req), %{}}

        %{account: account} ->
          # Build upstream WS URL with the same headers as HTTP requests
          upstream_headers =
            CodexAPI.build_headers(account, true, config)
            |> Enum.map(fn {k, v} -> {to_string(k), v} end)

          upstream_url = "wss://chatgpt.com/backend-api/codex/responses"

          Logger.info("[codex_ws] upstream connect account=#{account.token.email}")

          state = %{
            account: account,
            manager: manager,
            config: config,
            upstream_url: upstream_url,
            upstream_headers: upstream_headers,
            upstream_pid: nil
          }

          {:cowboy_websocket, req, state, %{idle_timeout: 300_000}}
      end
    end
  end

  @impl true
  def websocket_init(state) do
    # Connect to upstream Codex WebSocket
    case connect_upstream(state) do
      {:ok, upstream_pid} ->
        Logger.info("[codex_ws] upstream connected")
        {:ok, %{state | upstream_pid: upstream_pid}}

      {:error, reason} ->
        Logger.error("[codex_ws] upstream connect failed: #{inspect(reason)}")
        {:stop, state}
    end
  end

  @impl true
  def websocket_handle({:text, data}, state) do
    # Forward client → upstream
    if state.upstream_pid do
      WebSockex.send_frame(state.upstream_pid, {:text, data})
    end

    {:ok, state}
  end

  def websocket_handle({:binary, data}, state) do
    # Forward client → upstream
    if state.upstream_pid do
      WebSockex.send_frame(state.upstream_pid, {:binary, data})
    end

    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  def websocket_handle({:pong, _}, state) do
    {:ok, state}
  end

  def websocket_handle(frame, state) do
    Logger.debug("[codex_ws] unexpected client frame: #{inspect(frame)}")
    {:ok, state}
  end

  @impl true
  def websocket_info({:upstream_frame, {:text, data}}, state) do
    {:reply, {:text, data}, state}
  end

  def websocket_info({:upstream_frame, {:binary, data}}, state) do
    {:reply, {:binary, data}, state}
  end

  def websocket_info({:upstream_frame, :ping}, state) do
    {:reply, :ping, state}
  end

  def websocket_info({:upstream_frame, {:close, code, reason}}, state) do
    Logger.info("[codex_ws] upstream closed code=#{code} reason=#{reason}")
    {:reply, {:close, code, reason}, state}
  end

  def websocket_info({:upstream_closed, reason}, state) do
    Logger.info("[codex_ws] upstream connection closed: #{inspect(reason)}")
    {:stop, state}
  end

  def websocket_info({:DOWN, _ref, :process, pid, reason}, %{upstream_pid: pid} = state) do
    Logger.warning("[codex_ws] upstream process down: #{inspect(reason)}")
    {:stop, state}
  end

  def websocket_info(msg, state) do
    Logger.debug("[codex_ws] unexpected info: #{inspect(msg)}")
    {:ok, state}
  end

  @impl true
  def terminate(reason, _req, state) do
    Logger.info("[codex_ws] terminated reason=#{inspect(reason)}")

    if state.upstream_pid && Process.alive?(state.upstream_pid) do
      Process.exit(state.upstream_pid, :normal)
    end

    :ok
  end

  # ── Private ──

  defp connect_upstream(state) do
    caller = self()
    url = state.upstream_url
    headers = state.upstream_headers

    task = Task.async(fn ->
      WebSockex.start_link(
        url,
        __MODULE__.Upstream,
        %{caller: caller},
        extra_headers: headers
      )
    end)

    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, {:ok, pid}} -> {:ok, pid}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp extract_api_key(req) do
    # From Authorization header
    case :cowboy_req.header("authorization", req) do
      "Bearer " <> token -> token
      _ ->
        # From query param
        qs = :cowboy_req.parse_qs(req)
        case List.keyfind(qs, "key", 0) do
          {"key", key} -> key
          nil -> ""
        end
    end
  end

  defp valid_api_key?(config, key) do
    key != "" and MapSet.member?(config.api_keys, key)
  end

  # ── Upstream WebSocket client (runs in separate process) ──

  defmodule Upstream do
    @moduledoc false
    use WebSockex

    @impl true
    def handle_frame({type, data}, state) do
      send(state.caller, {:upstream_frame, {type, data}})
      {:ok, state}
    end

    @impl true
    def handle_disconnect(disconnect_map, state) do
      send(state.caller, {:upstream_closed, disconnect_map})
      {:ok, state}
    end
  end
end
