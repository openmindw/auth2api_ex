import Config

# Runtime configuration — loads YAML config and applies overrides
if config_env() == :prod do
  config_path = System.get_env("AUTH2API_CONFIG") || "config.yaml"

  if File.exists?(config_path) do
    config = Auth2ApiEx.Config.load_config(config_path)

    config :auth2api_ex, Auth2ApiEx.Server,
      port: config.port,
      host: if(config.host == "", do: "127.0.0.1", else: config.host)
  end
end
