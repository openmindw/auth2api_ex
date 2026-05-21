defmodule Auth2ApiEx.Providers.RegistryTest do
  use ExUnit.Case, async: false

  alias Auth2ApiEx.Providers.Registry
  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Auth.{TokenData, TokenStorage}

  setup do
    auth_dir = Path.join(System.tmp_dir!(), "registry-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(auth_dir)

    on_exit(fn ->
      # Stop named managers
      try do
        GenServer.stop(:anthropic_manager, :normal, 500)
      catch
        :exit, _ -> :ok
      end

      try do
        GenServer.stop(:codex_manager, :normal, 500)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(auth_dir)
    end)

    {:ok, auth_dir: auth_dir}
  end

  describe "Registry.build/1" do
    test "creates a registry with both providers", %{auth_dir: auth_dir} do
      registry = Registry.build(auth_dir)

      assert is_map(registry)
      assert Map.has_key?(registry, :providers)
      assert Map.has_key?(registry, :by_id)
      assert length(registry.providers) == 2

      provider_ids = Enum.map(registry.providers, & &1.id)
      assert :anthropic in provider_ids
      assert :codex in provider_ids
    end
  end

  describe "for_model/2" do
    setup %{auth_dir: auth_dir} do
      registry = Registry.build(auth_dir)
      {:ok, registry: registry}
    end

    test "routes claude- models to anthropic", %{registry: registry} do
      provider = Registry.for_model(registry, "claude-sonnet-4-6")
      assert provider.id == :anthropic

      provider = Registry.for_model(registry, "claude-opus-4-6")
      assert provider.id == :anthropic

      provider = Registry.for_model(registry, "claude-haiku-4-5-20251001")
      assert provider.id == :anthropic
    end

    test "routes gpt-5 models to codex", %{registry: registry} do
      provider = Registry.for_model(registry, "gpt-5.4")
      assert provider.id == :codex

      provider = Registry.for_model(registry, "gpt-5.2")
      assert provider.id == :codex

      provider = Registry.for_model(registry, "gpt-5.5")
      assert provider.id == :codex

      provider = Registry.for_model(registry, "gpt-5")
      assert provider.id == :codex
    end

    test "routes gpt-5-mini models to codex", %{registry: registry} do
      provider = Registry.for_model(registry, "gpt-5.4-mini")
      assert provider.id == :codex
    end

    test "routes gpt-5-codex models to codex", %{registry: registry} do
      provider = Registry.for_model(registry, "gpt-5.3-codex")
      assert provider.id == :codex
    end

    test "routes o-series models to codex", %{registry: registry} do
      provider = Registry.for_model(registry, "o4-mini")
      assert provider.id == :codex

      provider = Registry.for_model(registry, "o3")
      assert provider.id == :codex
    end

    test "routes codex- models to codex", %{registry: registry} do
      provider = Registry.for_model(registry, "codex-mini-latest")
      assert provider.id == :codex
    end

    test "falls back to anthropic for unknown models", %{registry: registry} do
      provider = Registry.for_model(registry, "gpt-4o")
      assert provider.id == :anthropic

      provider = Registry.for_model(registry, "unknown-model")
      assert provider.id == :anthropic
    end

    test "falls back to anthropic for gpt-3.5 turbo", %{registry: registry} do
      provider = Registry.for_model(registry, "gpt-3.5-turbo")
      assert provider.id == :anthropic
    end
  end

  describe "with_accounts/1" do
    setup %{auth_dir: auth_dir} do
      registry = Registry.build(auth_dir)
      {:ok, registry: registry, auth_dir: auth_dir}
    end

    test "returns empty list when no accounts exist", %{registry: registry} do
      providers = Registry.with_accounts(registry)
      assert providers == []
    end

    test "returns only providers with accounts", %{registry: registry, auth_dir: auth_dir} do
      # Add anthropic account
      anthropic_token = %TokenData{
        access_token: "at",
        refresh_token: "rt",
        email: "claude@example.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "claude-uuid",
        provider: "anthropic"
      }

      TokenStorage.save_token(auth_dir, anthropic_token)
      Manager.load(:anthropic_manager)

      providers = Registry.with_accounts(registry)
      assert length(providers) == 1
      assert hd(providers).id == :anthropic

      # Add codex account
      codex_token = %TokenData{
        access_token: "cat",
        refresh_token: "crt",
        email: "codex@example.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "codex-uuid",
        provider: "codex"
      }

      TokenStorage.save_token(auth_dir, codex_token)
      Manager.load(:codex_manager)

      providers = Registry.with_accounts(registry)
      assert length(providers) == 2
    end
  end
end
