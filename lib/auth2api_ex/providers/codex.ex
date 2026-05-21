defmodule Auth2ApiEx.Providers.Codex do
  @moduledoc """
  Codex provider — wraps CodexOAuth, AccountManager, and Codex API modules.
  """

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Auth.CodexOAuth
  alias Auth2ApiEx.Upstream.CodexModels

  @model_re ~r/^(gpt-5(\.|-)|gpt-5$|o\d|codex-|gpt-image-)/i

  @doc """
  Build the Codex provider — starts the AccountManager and returns the provider map.
  """
  def build(auth_dir, opts \\ []) do
    manager_name = opts[:codex_manager] || :codex_manager
    utilization_store = opts[:utilization_store] || Auth2ApiEx.Accounts.UtilizationStore

    case Manager.start_link(
           auth_dir: auth_dir,
           provider: "codex",
           refresh_fn: &CodexOAuth.refresh_tokens_with_retry/1,
           refresh_policy: {:since_last_refresh, 8 * 86_400_000},
           name: manager_name,
           utilization_store: utilization_store
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> raise "Failed to start codex manager: #{inspect(reason)}"
    end

    Manager.load(manager_name)

    %{
      id: :codex,
      native_format: :openai_responses,
      manager: manager_name,
      matches_model?: fn model -> Regex.match?(@model_re, model) end,
      list_models: fn -> CodexModels.list_models(manager_name) end
    }
  end
end
