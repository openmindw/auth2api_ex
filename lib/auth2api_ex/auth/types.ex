defmodule Auth2ApiEx.Auth.Types do
  @moduledoc """
  Type definitions for OAuth token data and storage.
  """

  @type provider_id :: String.t()

  @type pkce_codes :: %{
          code_verifier: String.t(),
          code_challenge: String.t()
        }

  @type token_data :: %Auth2ApiEx.Auth.TokenData{
          access_token: String.t(),
          refresh_token: String.t(),
          email: String.t(),
          expires_at: String.t(),
          account_uuid: String.t(),
          provider: String.t(),
          plan_type: String.t() | nil,
          id_token: String.t() | nil,
          chatgpt_account_id: String.t() | nil
        }

  @type token_storage :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          last_refresh: String.t(),
          email: String.t(),
          type: String.t(),
          expired: String.t(),
          account_uuid: String.t() | nil,
          provider: String.t() | nil,
          plan_type: String.t() | nil,
          id_token: String.t() | nil,
          chatgpt_account_id: String.t() | nil
        }
end
