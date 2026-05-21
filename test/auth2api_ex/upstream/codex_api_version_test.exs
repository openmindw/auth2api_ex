defmodule Auth2ApiEx.Upstream.CodexAPIVersionTest do
  use ExUnit.Case, async: true
  alias Auth2ApiEx.Upstream.CodexAPI
  alias Auth2ApiEx.Accounts.Manager.AvailableAccount
  alias Auth2ApiEx.Auth.TokenData

  @default_version "0.125.0"

  setup do
    account = %AvailableAccount{
      token: %TokenData{
        access_token: "test-token",
        email: "test@example.com",
        expires_at: "2099-01-01T00:00:00Z"
      },
      chatgpt_account_id: "acct-123"
    }

    {:ok, account: account}
  end

  describe "cli-version default behavior" do
    test "uses default cli_version when cloaking.codex is empty", %{account: account} do
      config = %{cloaking: %{}}
      headers = CodexAPI.build_headers(account, false, config)

      assert {"version", @default_version} in headers
    end

    test "uses default cli_version when cloaking.codex has no cli-version", %{account: account} do
      config = %{cloaking: %{codex: %{"originator" => "custom_origin"}}}
      headers = CodexAPI.build_headers(account, false, config)

      assert {"version", @default_version} in headers
    end
  end

  describe "cli-version configuration override" do
    test "uses configured cli-version from cloaking.codex.cli-version", %{account: account} do
      config = %{cloaking: %{codex: %{"cli-version" => "0.130.0"}}}
      headers = CodexAPI.build_headers(account, false, config)

      assert {"version", "0.130.0"} in headers
      refute {"version", @default_version} in headers
    end

    test "cli-version affects both version header and User-Agent", %{account: account} do
      config = %{cloaking: %{codex: %{"cli-version" => "0.200.0"}}}
      headers = CodexAPI.build_headers(account, false, config)

      assert {"version", "0.200.0"} in headers

      {_, ua} = Enum.find(headers, fn {k, _} -> k == "User-Agent" end)
      assert String.starts_with?(ua, "codex_cli_rs/0.200.0")
    end
  end

  describe "user-agent custom override" do
    test "custom user-agent takes priority over cli-version in header", %{account: account} do
      config = %{cloaking: %{codex: %{"user-agent" => "my-agent/1.0"}}}
      headers = CodexAPI.build_headers(account, false, config)

      assert {"User-Agent", "my-agent/1.0"} in headers
      # version header still uses cli-version (or default)
      assert {"version", @default_version} in headers
    end

    test "custom user-agent + cli-version: version header uses configured version", %{
      account: account
    } do
      config = %{
        cloaking: %{codex: %{"user-agent" => "my-agent/1.0", "cli-version" => "0.140.0"}}
      }

      headers = CodexAPI.build_headers(account, false, config)

      assert {"User-Agent", "my-agent/1.0"} in headers
      assert {"version", "0.140.0"} in headers
    end
  end
end
