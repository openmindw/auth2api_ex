defmodule Auth2ApiEx.Admin.ReloadTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Auth2ApiEx.Accounts.Manager
  alias Auth2ApiEx.Auth.{TokenData, TokenStorage}

  setup do
    auth_dir = Path.join(System.tmp_dir!(), "reload-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(auth_dir)

    config_path =
      Path.join(System.tmp_dir!(), "reload-test-cfg-#{System.unique_integer([:positive])}.yaml")

    File.write!(config_path, """
    api-keys:
      - sk-test-key
    admin:
      username: admin
      password: secret
    """)

    config = Auth2ApiEx.Config.load_config(config_path)
    Application.put_env(:auth2api_ex, :config, config)
    Application.put_env(:auth2api_ex, :config_path, config_path)

    name = String.to_atom("reload_mgr_#{System.unique_integer([:positive])}")
    {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: name)
    Application.put_env(:auth2api_ex, :manager_name, name)

    on_exit(fn ->
      Application.delete_env(:auth2api_ex, :manager_name)
      Application.delete_env(:auth2api_ex, :config)
      Application.delete_env(:auth2api_ex, :config_path)

      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(auth_dir)
      File.rm(config_path)
    end)

    %{auth_dir: auth_dir, config: config, mgr: name}
  end

  defp basic_auth_header, do: {"authorization", "Basic " <> Base.encode64("admin:secret")}

  describe "Manager.reload/1" do
    test "detects new accounts added on disk", %{auth_dir: auth_dir, mgr: mgr} do
      result = Manager.reload(mgr)
      assert result.added == []
      assert result.updated == []

      # Add a new token file on disk
      token = %TokenData{
        access_token: "new-at",
        refresh_token: "new-rt",
        email: "new@example.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "new-uuid"
      }

      TokenStorage.save_token(auth_dir, token)

      result = Manager.reload(mgr)
      assert "new@example.com" in result.added
      assert Manager.account_count(mgr) == 1
    end

    test "detects updated access tokens", %{auth_dir: auth_dir, mgr: mgr} do
      token = %TokenData{
        access_token: "original-at",
        refresh_token: "rt",
        email: "update@example.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "uuid"
      }

      TokenStorage.save_token(auth_dir, token)
      Manager.reload(mgr)

      # Update the token on disk with new access_token
      updated = %{token | access_token: "updated-at"}
      TokenStorage.save_token(auth_dir, updated)

      result = Manager.reload(mgr)
      assert "update@example.com" in result.updated
    end

    test "keeps in-memory accounts when removed from disk", %{auth_dir: auth_dir, mgr: mgr} do
      token = %TokenData{
        access_token: "at",
        refresh_token: "rt",
        email: "keep@example.com",
        expires_at: "2099-01-01T00:00:00Z",
        account_uuid: "uuid"
      }

      TokenStorage.save_token(auth_dir, token)
      Manager.reload(mgr)
      assert Manager.account_count(mgr) == 1

      # Delete the token file
      TokenStorage.delete_token(auth_dir, "keep@example.com")

      result = Manager.reload(mgr)
      assert result.added == []
      assert result.updated == []
      # Account should still be in memory
      assert Manager.account_count(mgr) == 1
    end
  end

  describe "POST /admin/reload" do
    setup %{auth_dir: auth_dir} do
      # Set up manager environment for admin handler
      mgr_name = String.to_atom("admin_reload_#{System.unique_integer([:positive])}")
      {:ok, pid} = Manager.start_link(auth_dir: auth_dir, name: mgr_name)
      Application.put_env(:auth2api_ex, :manager_name, mgr_name)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
        catch
          :exit, _ -> :ok
        end
      end)

      %{mgr_name: mgr_name}
    end

    test "returns reload result as JSON", %{mgr_name: mgr_name} do
      # Re-set manager name (might have been changed by previous test)
      Application.put_env(:auth2api_ex, :manager_name, mgr_name)

      {key, value} = basic_auth_header()

      conn =
        conn(:post, "/admin/api/reload")
        |> put_req_header(key, value)
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_map(body["reload"])
      assert Map.has_key?(body["reload"], "added")
      assert Map.has_key?(body["reload"], "updated")
    end

    test "returns 401 without auth" do
      conn =
        conn(:post, "/admin/api/reload")
        |> Auth2ApiEx.Admin.Handler.call(Auth2ApiEx.Admin.Handler.init([]))

      assert conn.status == 401
    end
  end
end
