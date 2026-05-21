defmodule Auth2ApiEx.Server do
  @moduledoc """
  Plug-based HTTP server with routing, CORS, rate limiting, and API key auth.
  """

  use Plug.Router

  alias Auth2ApiEx.Config
  alias Auth2ApiEx.Utils.Common
  alias Auth2ApiEx.Providers.Registry
  alias Auth2ApiEx.Health

  import Auth2ApiEx.PlugHelpers, only: [send_json: 3]

  @localhost_re ~r/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/

  plug(:put_config)
  plug(Auth2ApiEx.Utils.RequestDecompression)
  plug(:parse_body)
  plug(:cors)
  plug(:rate_limit)
  plug(:match)
  plug(:dispatch)

  # ── Health check ──

  get "/health" do
    registry = conn.assigns[:registry]
    health = Health.check_public(registry)
    send_json(conn, 200, health)
  end

  get "/healthz" do
    conn = require_admin_basic_auth(conn)

    if conn.halted do
      conn
    else
      registry = conn.assigns[:registry]
      health = Health.check_full(registry)
      send_json(conn, 200, health)
    end
  end

  # ── Admin endpoints ──

  match "/admin" do
    Auth2ApiEx.Admin.Handler.call(conn, Auth2ApiEx.Admin.Handler.init([]))
  end

  match "/admin/*_rest" do
    Auth2ApiEx.Admin.Handler.call(conn, Auth2ApiEx.Admin.Handler.init([]))
  end

  # ── Models ──

  get "/v1/models" do
    conn = require_api_key(conn)

    if conn.halted do
      conn
    else
      registry = conn.assigns[:registry]
      providers = Registry.with_accounts(registry)

      models =
        Enum.flat_map(providers, fn provider ->
          case provider.list_models.() do
            {:ok, list} when is_list(list) -> list
            list when is_list(list) -> list
            _ -> []
          end
        end)
        |> Enum.uniq_by(fn m -> m.id end)

      send_json(conn, 200, %{
        object: "list",
        data:
          Enum.map(models, fn m ->
            %{
              id: m.id,
              object: "model",
              created: System.system_time(:second),
              owned_by: m.owned_by
            }
          end)
      })
    end
  end

  # ── OpenAI compatible ──

  post "/v1/chat/completions" do
    conn = require_api_key(conn)

    if conn.halted do
      conn
    else
      config = conn.assigns[:config]
      Auth2ApiEx.Handlers.OpenAI.handle_chat_completions(conn, config)
    end
  end

  post "/v1/responses" do
    conn = require_api_key(conn)

    if conn.halted do
      conn
    else
      config = conn.assigns[:config]
      Auth2ApiEx.Handlers.OpenAI.handle_responses(conn, config)
    end
  end

  # ── Anthropic native passthrough ──

  post "/v1/messages" do
    conn = require_api_key(conn)

    if conn.halted do
      conn
    else
      config = conn.assigns[:config]
      Auth2ApiEx.Handlers.Anthropic.handle_messages(conn, config)
    end
  end

  post "/v1/messages/count_tokens" do
    conn = require_api_key(conn)

    if conn.halted do
      conn
    else
      config = conn.assigns[:config]
      Auth2ApiEx.Handlers.Anthropic.handle_count_tokens(conn, config)
    end
  end

  # ── OpenAI Images API ──

  post "/v1/images/generations" do
    conn = require_api_key(conn)

    if conn.halted do
      conn
    else
      config = conn.assigns[:config]
      Auth2ApiEx.Handlers.OpenAIImages.handle_generations(conn, config)
    end
  end

  post "/v1/images/edits" do
    conn = require_api_key(conn)

    if conn.halted do
      conn
    else
      config = conn.assigns[:config]
      Auth2ApiEx.Handlers.OpenAIImages.handle_edits(conn, config)
    end
  end

  # ── Catch-all ──

  match _ do
    send_json(conn, 404, %{error: %{message: "Not found"}})
  end

  # ── Plugs ──

  defp put_config(conn, _opts) do
    config = conn.assigns[:config] || Application.get_env(:auth2api_ex, :config)
    registry = conn.assigns[:registry] || Application.get_env(:auth2api_ex, :registry)

    Plug.Conn.assign(conn, :config, config)
    |> Plug.Conn.assign(:registry, registry)
  end

  defp parse_body(conn, _opts) do
    config = conn.assigns[:config]
    limit = Config.parse_body_limit(config.body_limit)

    # If RequestDecompression plug already decompressed the body,
    # parse JSON from the decompressed raw body directly.
    case conn.private[:raw_body] do
      nil ->
        content_type = get_content_type(conn)

        opts =
          if content_type && String.starts_with?(content_type, "multipart/form-data") do
            [
              parsers: [{Plug.Parsers.JSON, json_decoder: Jason}, Plug.Parsers.MULTIPART],
              length: limit
            ]
          else
            [parsers: [{Plug.Parsers.JSON, json_decoder: Jason}], length: limit]
          end

        conn = Plug.Parsers.call(conn, Plug.Parsers.init(opts))
        Plug.Conn.assign(conn, :parsed_body, conn.body_params)

      body when is_binary(body) and body != "" ->
        if byte_size(body) <= limit do
          case Jason.decode(body) do
            {:ok, parsed} ->
              Plug.Conn.assign(conn, :parsed_body, parsed)

            {:error, _reason} ->
              conn
              |> send_json(400, %{error: %{message: "Invalid JSON body"}})
              |> Plug.Conn.halt()
          end
        else
          conn
          |> send_json(413, %{error: %{message: "Request body too large"}})
          |> Plug.Conn.halt()
        end

      _ ->
        # Empty raw_body — skip parsing
        conn
    end
  rescue
    _ ->
      conn
      |> send_json(400, %{error: %{message: "Invalid request body"}})
      |> Plug.Conn.halt()
  end

  defp cors(conn, _opts) do
    origin = List.first(Plug.Conn.get_req_header(conn, "origin")) || ""

    conn =
      if Regex.match?(@localhost_re, origin) do
        Plug.Conn.put_resp_header(conn, "access-control-allow-origin", origin)
      else
        conn
      end

    conn =
      conn
      |> Plug.Conn.put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> Plug.Conn.put_resp_header(
        "access-control-allow-headers",
        "Content-Type, Authorization, x-api-key"
      )

    if conn.method == "OPTIONS" do
      conn
      |> Plug.Conn.send_resp(204, "")
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  # Rate limiting per IP
  @rate_limit_window_ms 60_000
  @rate_limit_max 60

  defp rate_limit(conn, _opts) do
    if String.starts_with?(conn.request_path, "/v1") do
      ip = conn.remote_ip |> :inet.ntoa() |> to_string()
      now = System.system_time(:millisecond)

      case :ets.lookup(:auth2api_ex_rate_limit, ip) do
        [{^ip, count, reset_at}] when now <= reset_at ->
          if count >= @rate_limit_max do
            conn
            |> send_json(429, %{error: %{message: "Too many requests"}})
            |> Plug.Conn.halt()
          else
            :ets.insert(:auth2api_ex_rate_limit, {ip, count + 1, reset_at})
            conn
          end

        _ ->
          :ets.insert(:auth2api_ex_rate_limit, {ip, 1, now + @rate_limit_window_ms})
          conn
      end
    else
      conn
    end
  end

  defp get_content_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [ct | _] -> String.downcase(ct)
      _ -> nil
    end
  end

  defp require_admin_basic_auth(conn) do
    config = conn.assigns[:config]

    with [header | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         "Basic " <> encoded <- header,
         {:ok, decoded} <- Base.decode64(encoded),
         [username, password] <- String.split(decoded, ":", parts: 2),
         true <- secure_compare(username, config.admin_username || ""),
         true <- secure_compare(password, config.admin_password || "") do
      conn
    else
      _ ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Basic realm="auth2api_ex admin"))
        |> send_json(401, %{error: %{message: "Admin credentials required"}})
        |> Plug.Conn.halt()
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false

  defp require_api_key(conn) do
    config = conn.assigns[:config]
    key = Common.extract_api_key(conn)

    cond do
      key == "" ->
        conn
        |> send_json(401, %{error: %{message: "Missing API key"}})
        |> Plug.Conn.halt()

      !MapSet.member?(config.api_keys, key) ->
        conn
        |> send_json(403, %{error: %{message: "Invalid API key"}})
        |> Plug.Conn.halt()

      true ->
        conn
    end
  end
end
