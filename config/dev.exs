import Config

config :auth2api_ex, Auth2ApiEx.Server, port: 8318

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
