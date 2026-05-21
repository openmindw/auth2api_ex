defmodule Auth2ApiEx.HttpE2ETest.PlugWrapper do
  def init(opts), do: opts

  def call(conn, opts) do
    config = Keyword.fetch!(opts, :config)
    registry = Keyword.fetch!(opts, :registry)
    test_plug = Keyword.get(opts, :test_plug)

    conn
    |> Plug.Conn.assign(:config, config)
    |> Plug.Conn.assign(:registry, registry)
    |> Plug.Conn.assign(:test_plug, test_plug)
    |> Auth2ApiEx.Server.call(Auth2ApiEx.Server.init([]))
  end
end

defmodule Auth2ApiEx.HttpE2ETest do
  use ExUnit.Case, async: true

  alias Auth2ApiEx.Auth.{TokenData, TokenStorage}

  defp setup_e2e_server(test_plug \\ nil) do
    # Ensure all dependent applications are started (needed for req and cowboy)
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:ezstd)

    # Initialize global ETS tables if they don't exist yet (e.g. under --no-start)
    if :ets.info(:auth2api_ex_sessions) == :undefined do
      :ets.new(:auth2api_ex_sessions, [:set, :public, :named_table])
    end

    if :ets.info(:auth2api_ex_rate_limit) == :undefined do
      :ets.new(:auth2api_ex_rate_limit, [:set, :public, :named_table])
    end

    # We need a temp directory for our E2E config & token files
    auth_dir = "/tmp/auth2api_ex_e2e_#{System.unique_integer([:positive])}"
    File.mkdir_p!(auth_dir)

    token = %TokenData{
      access_token: "e2e-upstream-token",
      refresh_token: "rt",
      email: "e2e-user@test.com",
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "e2e-uuid",
      chatgpt_account_id: "e2e-acct",
      provider: "codex"
    }

    # Save token to the new temp directory
    :ok = TokenStorage.save_token(auth_dir, token)

    # Start an isolated, dynamic utilization store
    util_store_name = :"utilization_store_e2e_#{System.unique_integer([:positive])}"
    {:ok, util_store_pid} = Auth2ApiEx.Accounts.UtilizationStore.start_link(
      dir: Path.join(auth_dir, "usage_stats"),
      name: util_store_name
    )

    # Start dynamic managers and build custom registry
    codex_mgr = :"codex_manager_e2e_#{System.unique_integer([:positive])}"
    anthropic_mgr = :"anthropic_manager_e2e_#{System.unique_integer([:positive])}"

    registry =
      Auth2ApiEx.Providers.Registry.build(auth_dir,
        codex_manager: codex_mgr,
        anthropic_manager: anthropic_mgr,
        utilization_store: util_store_name
      )

    # Create local config struct
    test_config = %Auth2ApiEx.Config{
      host: "127.0.0.1",
      port: 0,
      auth_dir: auth_dir,
      api_keys: MapSet.new(["sk-e2e-test-key"]),
      timeouts: %{
        messages_ms: 10000,
        stream_messages_ms: 10000,
        count_tokens_ms: 10000
      }
    }

    # Start dynamic Cowboy HTTP server under a custom ref
    ref = :"cowboy_server_e2e_#{System.unique_integer([:positive])}"
    {:ok, _cowboy_pid} =
      Plug.Cowboy.http(Auth2ApiEx.HttpE2ETest.PlugWrapper, [config: test_config, registry: registry, test_plug: test_plug],
        port: 0,
        ref: ref
      )

    port = :ranch.get_port(ref)

    on_exit(fn ->
      # Stop Cowboy server
      Plug.Cowboy.shutdown(ref)

      # Stop dynamic managers
      for name <- [codex_mgr, anthropic_mgr] do
        if pid = Process.whereis(name) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end

      # Stop dynamic utilization store
      try do
        GenServer.stop(util_store_pid)
      catch
        :exit, _ -> :ok
      end

      # Clean up temp files
      File.rm_rf!(auth_dir)
    end)

    %{port: port}
  end

  test "CORS OPTIONS preflight request returns 204 with headers" do
    %{port: port} = setup_e2e_server()
    client_url = "http://127.0.0.1:#{port}/v1/responses"

    response =
      Req.request!(
        method: :options,
        url: client_url,
        headers: [
          {"origin", "http://localhost:3000"},
          {"access-control-request-method", "POST"},
          {"access-control-request-headers", "content-type, authorization"}
        ]
      )

    assert response.status == 204
    assert Req.Response.get_header(response, "access-control-allow-origin") == ["http://localhost:3000"]
    assert Req.Response.get_header(response, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
    assert Req.Response.get_header(response, "access-control-allow-headers") == ["Content-Type, Authorization, x-api-key"]
    assert response.body == ""
  end

  test "streaming POST request completes successfully with chunked SSE data" do
    # Set up our mock plug for the upstream ChatGPT call
    mock_upstream_plug = fn conn ->
      # Ensure headers sent to the upstream are correct
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer e2e-upstream-token"]

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      # Send a stream of SSE events
      {:ok, conn} = Plug.Conn.chunk(conn, "event: response.created\ndata: {}\n\n")
      {:ok, conn} = Plug.Conn.chunk(conn, "event: response.output_text.delta\ndata: {\"delta\":\"Hello\"}\n\n")
      {:ok, conn} = Plug.Conn.chunk(conn, "event: response.output_text.delta\ndata: {\"delta\":\"!\"}\n\n")
      {:ok, conn} = Plug.Conn.chunk(conn, "event: response.completed\ndata: {\"response\":{\"usage\":{\"input_tokens\":5,\"output_tokens\":2}}}\n\n")

      conn
    end

    %{port: port} = setup_e2e_server(mock_upstream_plug)
    client_url = "http://127.0.0.1:#{port}/v1/responses"

    body = %{
      "model" => "gpt-5.4-mini",
      "input" => "hello",
      "stream" => true
    }

    # Make the request to our local HTTP server and collect the chunked response
    {:ok, response} =
      Req.post(client_url,
        json: body,
        headers: [{"authorization", "Bearer sk-e2e-test-key"}],
        into: fn {:data, chunk}, {req, resp} ->
          {:cont, {req, update_in(resp.body, &((&1 || "") <> chunk))}}
        end
      )

    assert response.status == 200
    [content_type | _] = Req.Response.get_header(response, "content-type")
    assert String.contains?(content_type, "text/event-stream")

    # Confirm that we received all streamed events correctly
    assert response.body =~ "event: response.created"
    assert response.body =~ "event: response.output_text.delta"
    assert response.body =~ "Hello"
    assert response.body =~ "!"
    assert response.body =~ "event: response.completed"
  end
end
