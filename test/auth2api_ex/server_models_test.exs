defmodule Auth2ApiEx.ServerModelsTest do
  use ExUnit.Case, async: true

  alias Auth2ApiEx.Server

  test "/v1/models accepts providers that return {:ok, list}" do
    provider = %{
      id: :anthropic,
      manager: :test_manager,
      list_models: fn -> {:ok, [%{id: "gpt-5.4", owned_by: "openai"}]} end
    }

    registry = %{providers: [provider], by_id: %{anthropic: provider}}

    conn =
      Plug.Test.conn(:get, "/v1/models")
      |> Plug.Conn.put_req_header("authorization", "Bearer sk-test")
      |> Plug.Conn.assign(:registry, registry)
      |> Plug.Conn.assign(
        :config,
        %Auth2ApiEx.Config{
          body_limit: "200mb",
          api_keys: MapSet.new(["sk-test"])
        }
      )

    conn = Server.call(conn, [])

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["object"] == "list"
    assert [%{"id" => "gpt-5.4", "owned_by" => "openai"}] = body["data"]
  end
end
