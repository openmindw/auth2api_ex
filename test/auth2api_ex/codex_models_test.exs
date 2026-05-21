defmodule Auth2ApiEx.CodexModelsTest do
  @moduledoc """
  Parity tests for `Auth2ApiEx.Upstream.CodexModels` against the Node.js
  reference (`codex-provider-ref/src/upstream/codex-models.ts`).

  Verifies:
    - Successful upstream fetch returns the upstream model list.
    - ETag is captured from response and sent on next call as If-None-Match.
    - `304 Not Modified` returns cached models without re-fetching the body.
    - Cache TTL is respected (within TTL → no upstream call).
    - On upstream failure, returns the previously cached list (stale-while-error).
    - When no cache and upstream fails, returns the static fallback list.
    - Authorization, ChatGPT-Account-ID, User-Agent, Accept headers are sent.
  """

  use ExUnit.Case, async: false

  alias Auth2ApiEx.Upstream.CodexModels
  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Auth.TokenData

  setup do
    auth_dir = "/tmp/codex_models_test_#{System.unique_integer([:positive])}"
    File.mkdir_p!(auth_dir)
    name = String.to_atom("codex_models_mgr_#{System.unique_integer([:positive])}")
    {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)

    token = %TokenData{
      access_token: "fake-access-token",
      refresh_token: "rt",
      email: "test@example.com",
      expires_at: "2099-01-01T00:00:00Z",
      account_uuid: "uuid",
      chatgpt_account_id: "chat-acct-xyz"
    }

    Manager.add_account(name, token)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(auth_dir)
    end)

    # Reset module-level cache between tests.
    CodexModels.reset_cache()

    {:ok, manager: name}
  end

  describe "list_models/2" do
    test "returns upstream models on first call and caches them", %{manager: mgr} do
      stub = fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/backend-api/codex/models"
        # Required headers
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fake-access-token"]
        assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["chat-acct-xyz"]
        assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["auth2api_ex/1.0.0"]

        body =
          Jason.encode!(%{
            "models" => [
              %{"slug" => "gpt-5.5"},
              %{"slug" => "gpt-5.4-mini"}
            ]
          })

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("v1-abc"))
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, models} = CodexModels.list_models(mgr, plug: stub)

      assert models == [
               %{id: "gpt-5.5", owned_by: "openai"},
               %{id: "gpt-5.4-mini", owned_by: "openai"}
             ]
    end

    test "second call within TTL hits cache (no upstream request)", %{manager: mgr} do
      counter = :counters.new(1, [])

      stub = fn conn ->
        :counters.add(counter, 1, 1)

        body = Jason.encode!(%{"models" => [%{"slug" => "gpt-5.5"}]})

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("v1"))
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, _} = CodexModels.list_models(mgr, plug: stub)
      {:ok, _} = CodexModels.list_models(mgr, plug: stub)

      assert :counters.get(counter, 1) == 1
    end

    test "sends If-None-Match with cached ETag and accepts 304", %{manager: mgr} do
      counter = :counters.new(1, [])

      stub = fn conn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        case n do
          0 ->
            body = Jason.encode!(%{"models" => [%{"slug" => "gpt-5.5"}]})

            conn
            |> Plug.Conn.put_resp_header("etag", ~s("etag-v1"))
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, body)

          _ ->
            assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("etag-v1")]
            Plug.Conn.send_resp(conn, 304, "")
        end
      end

      {:ok, first} = CodexModels.list_models(mgr, plug: stub, ttl_ms: 0)
      {:ok, second} = CodexModels.list_models(mgr, plug: stub, ttl_ms: 0)

      assert first == second
      assert second == [%{id: "gpt-5.5", owned_by: "openai"}]
      assert :counters.get(counter, 1) == 2
    end

    test "stale-while-error: upstream 5xx returns previously cached models", %{manager: mgr} do
      counter = :counters.new(1, [])

      stub = fn conn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        case n do
          0 ->
            body = Jason.encode!(%{"models" => [%{"slug" => "gpt-5.5"}]})

            conn
            |> Plug.Conn.put_resp_header("etag", ~s("v1"))
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, body)

          _ ->
            Plug.Conn.send_resp(conn, 503, "Service Unavailable")
        end
      end

      {:ok, _} = CodexModels.list_models(mgr, plug: stub, ttl_ms: 0)
      {:ok, models} = CodexModels.list_models(mgr, plug: stub, ttl_ms: 0)

      assert models == [%{id: "gpt-5.5", owned_by: "openai"}]
    end

    test "no cache + upstream failure → falls back to static list", %{manager: mgr} do
      stub = fn conn -> Plug.Conn.send_resp(conn, 500, "internal error") end

      {:ok, models} = CodexModels.list_models(mgr, plug: stub)

      ids = Enum.map(models, & &1.id)
      assert "gpt-5.5" in ids
      assert "gpt-5.3-codex" in ids
      # All have owned_by == openai
      assert Enum.all?(models, &(&1.owned_by == "openai"))
    end

    test "no account loaded → returns fallback without HTTP call", %{manager: _mgr} do
      empty_dir = "/tmp/codex_models_empty_#{System.unique_integer([:positive])}"
      File.mkdir_p!(empty_dir)
      empty_name = String.to_atom("codex_models_empty_#{System.unique_integer([:positive])}")
      {:ok, _pid} = Manager.start_link(auth_dir: empty_dir, name: empty_name)

      called? = :counters.new(1, [])

      stub = fn conn ->
        :counters.add(called?, 1, 1)
        Plug.Conn.send_resp(conn, 200, ~s({"models":[]}))
      end

      {:ok, models} = CodexModels.list_models(empty_name, plug: stub)

      assert :counters.get(called?, 1) == 0
      ids = Enum.map(models, & &1.id)
      assert "gpt-5.5" in ids
      File.rm_rf!(empty_dir)
    end

    test "client_version query parameter is sent", %{manager: mgr} do
      stub = fn conn ->
        assert conn.query_string =~ "client_version="
        body = Jason.encode!(%{"models" => [%{"slug" => "gpt-5.5"}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      {:ok, _} = CodexModels.list_models(mgr, plug: stub)
    end
  end

  # ══════════════════════════════════════════════════
  # ETag normalization
  # ══════════════════════════════════════════════════

  describe "normalize_etag/1" do
    test "strips W/ prefix from weak ETags" do
      assert CodexModels.normalize_etag(~s(W/"abc123")) == ~s("abc123")
    end

    test "preserves strong ETags unchanged" do
      assert CodexModels.normalize_etag(~s("v1-abc-def")) == ~s("v1-abc-def")
    end

    test "handles ETags without quotes" do
      assert CodexModels.normalize_etag("v1-abc-def") == "v1-abc-def"
    end

    test "handles W/ prefix without quotes" do
      assert CodexModels.normalize_etag("W/v1-abc-def") == "v1-abc-def"
    end
  end

  describe "If-None-Match normalization in full fetch cycle" do
    test "normalizes W/ ETag before sending If-None-Match", %{manager: mgr} do
      counter = :counters.new(1, [])

      stub = fn conn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        case n do
          0 ->
            # Return weak ETag — the system should strip W/ prefix for storage
            body = Jason.encode!(%{"models" => [%{"slug" => "gpt-5.5"}]})

            conn
            |> Plug.Conn.put_resp_header("etag", ~s(W/"weak-etag-v1"))
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, body)

          _ ->
            # Should receive normalized ETag without W/ prefix
            assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("weak-etag-v1")]
            refute Plug.Conn.get_req_header(conn, "if-none-match") == [~s(W/"weak-etag-v1")]
            Plug.Conn.send_resp(conn, 304, "")
        end
      end

      {:ok, _} = CodexModels.list_models(mgr, plug: stub, ttl_ms: 0)
      {:ok, models} = CodexModels.list_models(mgr, plug: stub, ttl_ms: 0)

      assert models == [%{id: "gpt-5.5", owned_by: "openai"}]
      assert :counters.get(counter, 1) == 2
    end
  end
end
