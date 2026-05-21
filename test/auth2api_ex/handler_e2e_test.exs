defmodule Auth2ApiEx.HandlerE2ETest do
  @moduledoc """
  End-to-end tests for handler → proxy → upstream pipelines:
    - POST /v1/chat/completions (OpenAI form → Anthropic translated)
    - POST /v1/messages (Anthropic native passthrough)

  Uses Process dictionary plugs (:__auth2api_ex_anthropic_plug__) to
  intercept upstream HTTP, and (:__auth2api_ex_manager__) to inject a
  test GenServer name.
  """

  use ExUnit.Case, async: false

  alias Auth2ApiEx.Auth.TokenData
  alias Auth2ApiEx.Accounts.Manager

  @test_config %{
    debug: "off",
    cloaking: %{},
    timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
  }

  defp start_mgr do
    auth_dir = "/tmp/e2e_h_#{System.unique_integer([:positive])}"
    File.mkdir_p!(auth_dir)
    name = String.to_atom("e2e_mgr_#{System.unique_integer([:positive])}")

    {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)

    token = %TokenData{
      access_token: "e2e-tok",
      refresh_token: "rt",
      email: "e2e@test.com",
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "e2e-uuid"
    }

    Manager.add_account(name, token)

    Process.put(:__auth2api_ex_manager__, name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(auth_dir)
      Process.delete(:__auth2api_ex_anthropic_plug__)
      Process.delete(:__auth2api_ex_manager__)
    end)

    name
  end

  @tag :e2e
  test "chat completions returns OpenAI shape translated from Anthropic upstream" do
    start_mgr()

    Process.put(
      :__auth2api_ex_anthropic_plug__,
      make_plug(200, %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hello from Claude"}],
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      })
    )

    conn =
      build_chat_conn(%{
        "model" => "claude-sonnet-4-6",
        "messages" => [%{"role" => "user", "content" => "Hi"}]
      })

    conn = Auth2ApiEx.Handlers.OpenAI.handle_chat_completions(conn, @test_config)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["object"] == "chat.completion"
    [choice | _] = resp["choices"]
    assert choice["message"]["content"] == "Hello from Claude"
  end

  @tag :e2e
  test "chat completions translates Anthropic error to OpenAI shape" do
    start_mgr()

    # 429 is retryable; the test plug must survive multiple calls.
    # After cooldown, only one account remains, so the first call
    # is 429 → cooldown → retry → no account → account_unavailable.
    # To exercise the error_adapter path, use an unrecoverable 400.
    Process.put(
      :__auth2api_ex_anthropic_plug__,
      make_plug(400, %{
        "error" => %{"message" => "bad request", "type" => "invalid_request_error"}
      })
    )

    conn =
      build_chat_conn(%{
        "model" => "claude-sonnet-4-6",
        "messages" => [%{"role" => "user", "content" => "Hi"}]
      })

    conn = Auth2ApiEx.Handlers.OpenAI.handle_chat_completions(conn, @test_config)

    assert conn.status == 400
    resp = Jason.decode!(conn.resp_body)
    assert resp["error"]["message"] == "bad request"
  end

  @tag :e2e
  test "messages passthrough returns raw Anthropic response" do
    start_mgr()

    Process.put(
      :__auth2api_ex_anthropic_plug__,
      make_plug(200, %{
        "id" => "msg_passthru",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "passthrough works"}],
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 5}
      })
    )

    conn =
      Plug.Test.conn(:post, "/v1/messages")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")

    body = %{
      "model" => "claude-sonnet-4-6",
      "max_tokens" => 1024,
      "messages" => [%{"role" => "user", "content" => "hi"}]
    }

    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    conn = Plug.Conn.assign(conn, :parsed_body, body)

    conn = Auth2ApiEx.Handlers.Anthropic.handle_messages(conn, @test_config)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["id"] == "msg_passthru"
  end

  # ── Helpers ──

  defp build_chat_conn(body) do
    conn =
      Plug.Test.conn(:post, "/v1/chat/completions")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-e2e")
      |> Plug.Conn.assign(:registry, build_registry())

    conn = Plug.Conn.put_private(conn, :raw_body, Jason.encode!(body))
    Plug.Conn.assign(conn, :parsed_body, body)
  end

  defp make_plug(status, json) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(json))
    end
  end

  defp build_registry do
    mgr = Process.get(:__auth2api_ex_manager__, Manager)

    provider = %{
      id: :anthropic,
      native_format: :anthropic_messages,
      manager: mgr,
      matches_model?: fn _ -> true end,
      list_models: fn -> {:ok, []} end
    }

    %{providers: [provider], by_id: %{anthropic: provider}}
  end
end
