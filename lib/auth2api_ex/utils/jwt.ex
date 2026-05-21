defmodule Auth2ApiEx.Utils.JWT do
  @moduledoc """
  Minimal JWT payload decoder — no signature verification.
  Token is already received over TLS from the issuer, so we trust the payload.
  """

  @doc """
  Decode the payload (second segment) of a JWT without verifying the signature.
  Returns the decoded payload as a map, or raises on malformed input.
  """
  @spec decode_payload(String.t()) :: map()
  def decode_payload(jwt) when is_binary(jwt) do
    [_header, payload | _rest] = String.split(jwt, ".", parts: 3)

    payload
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> Base.decode64!(padding: false)
    |> Jason.decode!()
  end
end
