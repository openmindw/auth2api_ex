import Config

# Minimal test config to satisfy Config import during tests
config :logger, level: :warning
config :auth2api_ex, :http_client, Auth2ApiEx.MockHttpClient
# Don't start the HTTP listener during tests; it conflicts with running dev instance.
config :auth2api_ex, :start_http_server, false
