defmodule Auth2ApiEx.CodexResponsesIntegrationTest do
  @moduledoc """
  Integration tests for Codex /v1/responses path.

  Uses Req.Test plug stubs to simulate chatgpt.com upstream. Tests
  the non-stream path end-to-end to ensure the handler sends SSE
  only when streaming, and complete JSON when not streaming.
  """

  use ExUnit.Case, async: false

  alias Auth2ApiEx.Upstream.CodexAPI
  alias Auth2ApiEx.Accounts.Manager.AvailableAccount
  alias Auth2ApiEx.Auth.TokenData

  # ══════════════════════════════════════════════════
  # Non-stream: CodexAPI.call_codex_responses returns
  # plain JSON (not SSE chunks) when stream=false.
  # ══════════════════════════════════════════════════

  describe "CodexAPI.call_codex_responses/1 — non-stream" do
    test "returns complete JSON response body when stream=false" do
      upstream_json = %{
        "id" => "resp_abc",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "id" => "msg_1",
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Hello world"}]
          }
        ],
        "usage" => %{"input_tokens" => 50, "output_tokens" => 20}
      }

      stub = fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/backend-api/codex/responses"

        {:ok, raw_body, _} = Plug.Conn.read_body(conn)
        {:ok, parsed} = Jason.decode(raw_body)

        # P0: stream is forced to true upstream regardless of client value
        assert parsed["stream"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(upstream_json))
      end

      account = %AvailableAccount{
        token: %TokenData{
          access_token: "fake-token",
          email: "test@example.com",
          expires_at: "2099-01-01T00:00:00Z"
        },
        chatgpt_account_id: "acct-123"
      }

      config = %{
        cloaking: %{codex: %{}},
        timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
      }

      {:ok, %Req.Response{status: 200, body: body}} =
        CodexAPI.call_codex_responses(
          body: %{"model" => "gpt-5.4", "stream" => false, "input" => "hello"},
          account: account,
          config: config,
          plug: stub,
          stream: false
        )

      assert is_map(body)
      assert body["id"] == "resp_abc"
      assert body["status"] == "completed"
      # Must NOT be an async ref (stream=false should NOT use into: :self)
      refute match?(%{ref: _}, body)
    end

    test "non-stream body is not in SSE format (no event/data framing)" do
      upstream_json = %{
        "id" => "resp_xyz",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-5.4",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(upstream_json))
      end

      account = %AvailableAccount{
        token: %TokenData{
          access_token: "tok",
          email: "test@example.com",
          expires_at: "2099-01-01T00:00:00Z"
        },
        chatgpt_account_id: "acct"
      }

      config = %{
        cloaking: %{codex: %{}},
        timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
      }

      {:ok, %Req.Response{status: 200, body: body}} =
        CodexAPI.call_codex_responses(
          body: %{"model" => "gpt-5.4", "stream" => false, "input" => "test"},
          account: account,
          config: config,
          plug: stub,
          stream: false
        )

      # Should be a plain map, not binary, and definitely not SSE
      assert is_map(body)
      refute is_binary(body) && String.starts_with?(to_string(body), "event:")
      refute is_binary(body) && String.starts_with?(to_string(body), "data:")
    end
  end

  # ══════════════════════════════════════════════════
  # Stream path: CodexAPI.call_codex_responses sets
  # into: :self for async streaming.
  # ══════════════════════════════════════════════════

  describe "CodexAPI.call_codex_responses/1 — stream" do
    test "sets into: :self when stream=true" do
      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")
      end

      account = %AvailableAccount{
        token: %TokenData{
          access_token: "tok",
          email: "test@example.com",
          expires_at: "2099-01-01T00:00:00Z"
        },
        chatgpt_account_id: "acct"
      }

      config = %{
        cloaking: %{codex: %{}},
        timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
      }

      {:ok, %Req.Response{body: body}} =
        CodexAPI.call_codex_responses(
          body: %{"model" => "gpt-5.4", "stream" => true, "input" => "hi"},
          account: account,
          config: config,
          plug: stub
        )

      # With into: :self, body should be a ref map for async receive
      assert match?(%{ref: _}, body)
    end

    test "default stream=true sets into: :self" do
      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")
      end

      account = %AvailableAccount{
        token: %TokenData{
          access_token: "tok",
          email: "test@example.com",
          expires_at: "2099-01-01T00:00:00Z"
        },
        chatgpt_account_id: "acct"
      }

      config = %{
        cloaking: %{codex: %{}},
        timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
      }

      {:ok, %Req.Response{body: body}} =
        CodexAPI.call_codex_responses(
          body: %{"model" => "gpt-5.4", "input" => "hi"},
          account: account,
          config: config,
          plug: stub
        )

      # When stream is not specified, normalize_body defaults to true → into: :self
      assert match?(%{ref: _}, body)
    end
  end

  # ══════════════════════════════════════════════════
  # Error path: CodexAPI returns error responses.
  # ══════════════════════════════════════════════════

  describe "CodexAPI.call_codex_responses/1 — errors" do
    test "returns 400 with detail for bad requests" do
      stub = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"detail":"Model not found"}))
      end

      account = %AvailableAccount{
        token: %TokenData{
          access_token: "tok",
          email: "test@example.com",
          expires_at: "2099-01-01T00:00:00Z"
        },
        chatgpt_account_id: "acct"
      }

      config = %{
        cloaking: %{codex: %{}},
        timeouts: %{messages_ms: 60_000, stream_messages_ms: 600_000, count_tokens_ms: 30_000}
      }

      {:ok, %Req.Response{status: 400, body: body}} =
        CodexAPI.call_codex_responses(
          body: %{"model" => "gpt-5.4", "stream" => false, "input" => "hi"},
          account: account,
          config: config,
          plug: stub,
          stream: false
        )

      assert body["detail"] == "Model not found"
    end
  end
end
