defmodule Auth2ApiEx.ServerCorsTest do
  use ExUnit.Case, async: true

  alias Auth2ApiEx.Server

  test "OPTIONS CORS request returns 204 without raising Plug.Conn.NotSentError" do
    config = %Auth2ApiEx.Config{
      body_limit: "200mb",
      api_keys: MapSet.new(["sk-test"])
    }

    registry = %{providers: [], by_id: %{}}

    conn =
      Plug.Test.conn(:options, "/v1/chat/completions")
      |> Plug.Conn.put_req_header("origin", "http://localhost:3000")
      |> Plug.Conn.assign(:config, config)
      |> Plug.Conn.assign(:registry, registry)

    # In the current implementation, this call will raise Plug.Conn.NotSentError
    # because the response status (204) is put, but the response is never sent
    # and the connection pipeline is halted.
    conn = Server.call(conn, [])

    assert conn.status == 204
    assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:3000"]
    assert Plug.Conn.get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
    assert Plug.Conn.get_resp_header(conn, "access-control-allow-headers") == ["Content-Type, Authorization, x-api-key"]
    assert conn.resp_body == ""
  end
end
