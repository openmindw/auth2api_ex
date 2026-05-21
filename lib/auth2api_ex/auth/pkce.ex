defmodule Auth2ApiEx.Auth.PKCE do
  @moduledoc """
  PKCE (Proof Key for Code Exchange) code generation for OAuth.
  """

  alias Auth2ApiEx.Auth.Types

  @doc """
  Generate PKCE code verifier and challenge pair.
  Verifier: 96 random bytes → base64url
  Challenge: SHA256(verifier) → base64url
  """
  @spec generate_pkce_codes() :: Types.pkce_codes()
  def generate_pkce_codes do
    verifier_bytes = :crypto.strong_rand_bytes(96)
    code_verifier = base64url(verifier_bytes)

    challenge_hash =
      :crypto.hash(:sha256, code_verifier)

    code_challenge = base64url(challenge_hash)

    %{code_verifier: code_verifier, code_challenge: code_challenge}
  end

  defp base64url(data) do
    data
    |> Base.encode64(padding: false)
    |> String.replace("+", "-")
    |> String.replace("/", "_")
  end
end
