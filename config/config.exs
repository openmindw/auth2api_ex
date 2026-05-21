# General application configuration
import Config

config :auth2api_ex,
  config_path: "config.yaml"

config :auth2api_ex, Auth2ApiEx.Server, port: 8318

import_config "#{config_env()}.exs"
