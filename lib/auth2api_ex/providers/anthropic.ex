defmodule Auth2ApiEx.Providers.Anthropic do
  @moduledoc """
  Anthropic provider — wraps existing OAuth, AccountManager, and API modules.
  """

  alias Auth2ApiEx.Accounts.Manager

  @model_re ~r/^claude-/i

  @static_models [
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-sonnet-4-6",
    "claude-haiku-4-5-20251001",
    "claude-haiku-4-5",
    "opus",
    "sonnet",
    "haiku"
  ]

  @doc """
  Build the Anthropic provider — starts the AccountManager and returns the provider map.
  """
  def build(auth_dir, opts \\ []) do
    manager_name = opts[:anthropic_manager] || :anthropic_manager
    utilization_store = opts[:utilization_store] || Auth2ApiEx.Accounts.UtilizationStore

    case Manager.start_link(
           auth_dir: auth_dir,
           provider: "anthropic",
           refresh_fn: fn token -> Auth2ApiEx.Auth.OAuth.refresh_tokens_with_retry(token, 3) end,
           refresh_policy: :expires_lead,
           name: manager_name,
           utilization_store: utilization_store
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> raise "Failed to start anthropic manager: #{inspect(reason)}"
    end

    Manager.load(manager_name)

    %{
      id: :anthropic,
      native_format: :anthropic_messages,
      manager: manager_name,
      matches_model?: fn model -> Regex.match?(@model_re, model) end,
      list_models: fn ->
        {:ok, Enum.map(@static_models, fn id -> %{id: id, owned_by: "anthropic"} end)}
      end
    }
  end
end
