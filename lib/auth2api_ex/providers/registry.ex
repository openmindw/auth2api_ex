defmodule Auth2ApiEx.Providers.Registry do
  @moduledoc """
  Provider Registry — manages multiple providers and routes models to the correct one.

  ## Usage

      registry = Registry.build(auth_dir)
      provider = Registry.for_model(registry, "gpt-5.4")
      provider.id  # => :codex
  """

  alias Auth2ApiEx.Providers.{Anthropic, Codex}
  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Upstream.Translator

  @doc """
  Build the provider registry — initializes both Anthropic and Codex providers.
  """
  @spec build(String.t(), keyword()) :: map()
  def build(auth_dir, opts \\ []) do
    anthropic = Anthropic.build(auth_dir, opts)
    codex = Codex.build(auth_dir, opts)
    by_id = %{anthropic: anthropic, codex: codex}

    %{
      providers: [anthropic, codex],
      by_id: by_id
    }
  end

  @doc """
  Find the provider that matches the given model string.
  Resolves aliases first, then checks model regexes.
  Falls back to Anthropic for unknown models.
  """
  @spec for_model(map(), String.t()) :: map()
  def for_model(registry, model) do
    resolved = Translator.resolve_model(model)

    Enum.find(registry.providers, nil, fn p ->
      p.matches_model?.(resolved)
    end) || registry.by_id.anthropic
  end

  @doc """
  Return only providers that have at least one logged-in account.
  """
  @spec with_accounts(map()) :: [map()]
  def with_accounts(registry) do
    Enum.filter(registry.providers, fn p ->
      Manager.account_count(p.manager) > 0
    end)
  end
end
