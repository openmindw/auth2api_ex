defmodule Auth2ApiEx.CodexResponsesE2ETest do
  @moduledoc """
  End-to-end tests for /v1/responses → Codex handler → proxy → upstream.

  Stubs the upstream with Req.Test plug and exercises the full handler
  pipeline, verifying the handler never converts SSE to plain JSON
  (the original bug) and that upstream errors are translated to
  OpenAI shape.
  """

  use ExUnit.Case, async: false

  alias Auth2ApiEx.Auth.TokenData
  alias Auth2ApiEx.Accounts.Manager

  @test_config %{
    debug: "off",
    cloaking: %{codex: %{}},
    timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
  }

  setup do
    auth_dir = "/tmp/codex_e2e_#{System.unique_integer([:positive])}"
    File.mkdir_p!(auth_dir)

    manager_name = String.to_atom("codex_e2e_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Manager.start_link(
        auth_dir: auth_dir,
        provider: "codex",
        name: manager_name
      )

    token = %TokenData{
      access_token: "e2e-token",
      refresh_token: "rt",
      email: "e2e@test.com",
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "e2e-uuid",
      chatgpt_account_id: "e2e-acct",
      provider: "codex"
    }

    Manager.add_account(manager_name, token)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(auth_dir)
      Process.delete(:__auth2api_ex_codex_plug__)
    end)

    {:ok, manager: manager_name}
  end

  # ══════════════════════════════════════════════════════
  # Non-stream: handler returns plain JSON, not SSE
  # ══════════════════════════════════════════════════════

  @tag :e2e
  test "non-stream returns application/json with parsed body, not SSE", %{manager: mgr} do
    upstream_json = %{
      "id" => "resp_e2e",
      "object" => "response",
      "status" => "completed",
      "model" => "gpt-5.4",
      "output" => [
        %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "e2e"}]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
    }

    test_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(upstream_json))
    end

    Process.put(:__auth2api_ex_codex_plug__, test_plug)

    conn =
      Plug.Test.conn(:post, "/v1/responses")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:registry, build_registry(mgr))

    body = %{"model" => "gpt-5.4", "stream" => false, "input" => "hello"}
    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    conn = Plug.Conn.assign(conn, :parsed_body, body)

    conn = Auth2ApiEx.Handlers.OpenAI.handle_responses(conn, @test_config)

    assert conn.status == 200
    [ctype | _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.contains?(ctype, "application/json")
    refute String.starts_with?(conn.resp_body, "event:")
    refute String.starts_with?(conn.resp_body, "data:")
  end

  @tag :e2e
  test "non-stream response has correct JSON structure", %{manager: mgr} do
    upstream_json = %{
      "id" => "resp_struct",
      "object" => "response",
      "status" => "completed",
      "model" => "gpt-5.4",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }

    test_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(upstream_json))
    end

    Process.put(:__auth2api_ex_codex_plug__, test_plug)

    conn =
      Plug.Test.conn(:post, "/v1/responses")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:registry, build_registry(mgr))

    body = %{"model" => "gpt-5.4", "stream" => false, "input" => "test"}
    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    conn = Plug.Conn.assign(conn, :parsed_body, body)

    conn = Auth2ApiEx.Handlers.OpenAI.handle_responses(conn, @test_config)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["id"] == "resp_struct"
    assert resp["object"] == "response"
    assert resp["status"] == "completed"
  end

  @tag :e2e
  test "omitted stream drains upstream SSE into JSON instead of forcing downstream SSE", %{
    manager: mgr
  } do
    completed = %{
      "id" => "resp_default",
      "object" => "response",
      "status" => "completed",
      "model" => "gpt-5.4",
      "output" => [],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }

    message_item = %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "drained"}]
    }

    test_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        [
          "event: response.output_item.done\n",
          "data: #{Jason.encode!(%{"item" => message_item})}\n\n",
          "event: response.completed\n",
          "data: #{Jason.encode!(%{"response" => completed})}"
        ]
        |> IO.iodata_to_binary()
      )
    end

    Process.put(:__auth2api_ex_codex_plug__, test_plug)

    conn =
      Plug.Test.conn(:post, "/v1/responses")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:registry, build_registry(mgr))

    body = %{"model" => "gpt-5.4", "input" => "test"}
    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    conn = Plug.Conn.assign(conn, :parsed_body, body)

    conn = Auth2ApiEx.Handlers.OpenAI.handle_responses(conn, @test_config)

    assert %Plug.Conn{} = conn
    assert conn.status == 200
    [ctype | _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.contains?(ctype, "application/json")
    resp = Jason.decode!(conn.resp_body)
    assert resp["id"] == "resp_default"
    assert get_in(resp, ["output", Access.at(0), "content", Access.at(0), "text"]) == "drained"
  end

  @tag :e2e
  test "streaming response returns chunked Plug.Conn, not metric side-effect result", %{
    manager: mgr
  } do
    test_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "")
    end

    Process.put(:__auth2api_ex_codex_plug__, test_plug)

    conn =
      Plug.Test.conn(:post, "/v1/responses")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:registry, build_registry(mgr))

    body = %{"model" => "gpt-5.4", "stream" => true, "input" => "test"}
    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    conn = Plug.Conn.assign(conn, :parsed_body, body)

    conn = Auth2ApiEx.Handlers.OpenAI.handle_responses(conn, @test_config)

    assert %Plug.Conn{} = conn
    assert conn.status == 200
    assert conn.state == :chunked
    [ctype | _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.contains?(ctype, "text/event-stream")
  end

  @tag :e2e
  test "streaming response records Codex utilization headers", %{manager: mgr} do
    test_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-codex-primary-used-percent", "88")
      |> Plug.Conn.put_resp_header("x-codex-primary-reset-after-seconds", "604800")
      |> Plug.Conn.put_resp_header("x-codex-primary-window-minutes", "10080")
      |> Plug.Conn.put_resp_header("x-codex-secondary-used-percent", "42")
      |> Plug.Conn.put_resp_header("x-codex-secondary-reset-after-seconds", "18000")
      |> Plug.Conn.put_resp_header("x-codex-secondary-window-minutes", "300")
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        "event: response.completed\n" <>
          ~s(data: {"response":{"usage":{"input_tokens":3,"output_tokens":2}}}) <> "\n\n"
      )
    end

    Process.put(:__auth2api_ex_codex_plug__, test_plug)

    conn =
      Plug.Test.conn(:post, "/v1/responses")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:registry, build_registry(mgr))

    body = %{"model" => "gpt-5.4", "stream" => true, "input" => "test"}
    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    conn = Plug.Conn.assign(conn, :parsed_body, body)

    conn = Auth2ApiEx.Handlers.OpenAI.handle_responses(conn, @test_config)

    assert %Plug.Conn{} = conn
    assert conn.status == 200

    assert eventually?(fn ->
             [snapshot] = Manager.get_snapshots(mgr)

             snapshot.utilization_5h == 42.0 and
               snapshot.utilization_7d == 88.0 and
               snapshot.total_input_tokens == 3 and
               snapshot.total_output_tokens == 2
           end)
  end

  # ══════════════════════════════════════════════════════
  # Error: handler translates Codex error to OpenAI shape
  # ══════════════════════════════════════════════════════

  @tag :e2e
  test "upstream error body is translated via openai_error_body adapter", %{manager: mgr} do
    test_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"detail":"Model not found"}))
    end

    Process.put(:__auth2api_ex_codex_plug__, test_plug)

    conn =
      Plug.Test.conn(:post, "/v1/responses")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:registry, build_registry(mgr))

    body = %{"model" => "gpt-5.4", "stream" => false, "input" => "test"}
    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    conn = Plug.Conn.assign(conn, :parsed_body, body)

    conn = Auth2ApiEx.Handlers.OpenAI.handle_responses(conn, @test_config)

    assert conn.status == 400
    resp = Jason.decode!(conn.resp_body)
    assert resp["error"]["message"] == "Model not found"
    assert resp["error"]["type"] == "upstream_error"
    refute Map.has_key?(resp, "detail")
  end

  # ══════════════════════════════════════════════════════
  # Helpers
  # ══════════════════════════════════════════════════════

  defp build_registry(manager_name) do
    provider = %{
      id: :codex,
      native_format: :openai_responses,
      manager: manager_name,
      matches_model?: fn model -> Regex.match?(~r/^(gpt-5(\.|-)|gpt-5$|o\d|codex-)/i, model) end,
      list_models: fn -> {:ok, []} end
    }

    %{
      providers: [provider],
      by_id: %{codex: provider}
    }
  end

  defp eventually?(fun, attempts \\ 20)
  defp eventually?(_fun, 0), do: false

  defp eventually?(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually?(fun, attempts - 1)
    end
  end
end
