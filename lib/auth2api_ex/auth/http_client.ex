defmodule Auth2ApiEx.Auth.HttpClient do
  @moduledoc """
  Behaviour for HTTP interactions used by auth flows.
  """

  @callback get(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  @callback post(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
end
