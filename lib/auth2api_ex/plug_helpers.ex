defmodule Auth2ApiEx.PlugHelpers do
  @moduledoc """
  Shared Plug helper functions for JSON responses.
  Replaces Phoenix.Controller.json/2 since we use plain Plug.
  """

  @doc """
  Send a JSON response with the given status code and body.
  """
  @spec send_json(Plug.Conn.t(), integer(), map()) :: Plug.Conn.t()
  def send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
