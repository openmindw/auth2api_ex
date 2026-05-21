defmodule Auth2ApiEx.Providers.Types do
  @moduledoc """
  Provider behaviour — the interface every provider must implement.
  """

  @type provider_id :: :anthropic | :codex
  @type native_format :: :anthropic_messages | :openai_responses

  @callback id() :: provider_id()
  @callback native_format() :: native_format()
  @callback matches_model?(String.t()) :: boolean()
  @callback manager() :: atom()
end
