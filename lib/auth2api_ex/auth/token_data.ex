defmodule Auth2ApiEx.Auth.TokenData do
  @moduledoc """
  Struct representing OAuth token data.
  """

  defstruct access_token: "",
            refresh_token: "",
            email: "",
            expires_at: "",
            account_uuid: "",
            provider: "anthropic",
            plan_type: nil,
            id_token: nil,
            chatgpt_account_id: nil

  @type t :: %__MODULE__{
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
end
