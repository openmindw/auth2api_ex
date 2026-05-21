defmodule Auth2ApiEx.Admin.ConfigTest do
  use ExUnit.Case, async: true

  describe "load_config with admin section" do
    test "parses admin username and password" do
      path =
        write_yaml(%{
          "admin" => %{"username" => "root", "password" => "s3cret"},
          "api-keys" => ["sk-test"]
        })

      config = Auth2ApiEx.Config.load_config(path)
      assert config.admin_username == "root"
      assert config.admin_password == "s3cret"
    end

    test "defaults admin to nil when not configured" do
      path = write_yaml(%{"api-keys" => ["sk-test"]})
      config = Auth2ApiEx.Config.load_config(path)
      assert is_binary(config.admin_username)
      assert is_binary(config.admin_password)
    end

    test "preserves existing api key when config file omits api-keys" do
      path = write_yaml(%{"admin" => %{"username" => "root", "password" => "s3cret"}})

      File.write!(
        path,
        """
        admin:
          username: root
          password: s3cret
        """
      )

      config = Auth2ApiEx.Config.load_config(path)
      assert MapSet.size(config.api_keys) > 0
      assert File.read!(path) =~ "api-keys:"
    end
  end

  describe "add_api_key/2" do
    test "adds key to config file and returns updated config" do
      path = write_yaml(%{"api-keys" => ["sk-existing"]})
      {:ok, config} = Auth2ApiEx.Config.add_api_key(path, "sk-new")
      assert MapSet.member?(config.api_keys, "sk-new")
      assert MapSet.member?(config.api_keys, "sk-existing")

      reloaded = Auth2ApiEx.Config.load_config(path)
      assert MapSet.member?(reloaded.api_keys, "sk-new")
    end
  end

  describe "remove_api_key/2" do
    test "removes key from config file" do
      path = write_yaml(%{"api-keys" => ["sk-a", "sk-b"]})
      {:ok, config} = Auth2ApiEx.Config.remove_api_key(path, "sk-a")
      refute MapSet.member?(config.api_keys, "sk-a")
      assert MapSet.member?(config.api_keys, "sk-b")
    end

    test "returns error when key not found" do
      path = write_yaml(%{"api-keys" => ["sk-a"]})
      assert {:error, :not_found} = Auth2ApiEx.Config.remove_api_key(path, "sk-nonexistent")
    end
  end

  defp write_yaml(data) do
    path =
      Path.join(System.tmp_dir!(), "admin-cfg-test-#{System.unique_integer([:positive])}.yaml")

    yaml =
      Enum.map_join(data, "\n", fn
        {"api-keys", keys} ->
          "api-keys:\n" <> Enum.map_join(keys, "\n", &"  - #{&1}")

        {"admin", %{"username" => user, "password" => password}} ->
          "admin:\n  username: #{user}\n  password: #{password}"

        {key, value} ->
          "#{key}: #{value}"
      end)

    File.write!(path, yaml)
    path
  end
end
