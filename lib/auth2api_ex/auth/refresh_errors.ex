defmodule Auth2ApiEx.Auth.RefreshErrors do
  @moduledoc """
  Classify refresh-token permanent-failure types for 24h terminal cooldown.
  These errors indicate the refresh_token is permanently invalid and the user
  must re-authenticate via --login --provider=<provider>.
  """

  @type t :: :refresh_token_reused | :expired | :invalidated

  @doc """
  Return true if the error text indicates a permanent refresh-token failure.
  """
  @spec permanent?(String.t()) :: boolean()
  def permanent?(error_text) when is_binary(error_text) do
    error_text
    |> String.downcase()
    |> then(
      &(String.contains?(&1, "refresh token reused") or
          String.contains?(&1, "refresh_token_reused") or
          String.contains?(&1, "refresh token not found") or
          String.contains?(&1, "revoked") or
          String.contains?(&1, "invalid_grant") or
          String.contains?(&1, "invalid refresh") or
          String.contains?(&1, "expired refresh"))
    )
  end

  @doc """
  Classify a permanent refresh error into a specific type.
  """
  @spec classify(String.t()) :: t()
  def classify(error_text) when is_binary(error_text) do
    lower = String.downcase(error_text)

    cond do
      String.contains?(lower, "reused") -> :refresh_token_reused
      String.contains?(lower, "expired") -> :expired
      true -> :invalidated
    end
  end

  @doc """
  End-user facing message for re-authentication hint.
  """
  @spec reauth_hint(String.t()) :: String.t()
  def reauth_hint(provider \\ "anthropic") do
    "Refresh token permanently invalid. Run: --login --provider=#{provider}"
  end
end
