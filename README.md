# auth2api_ex

auth2api_ex is an Elixir implementation of an OAuth-to-API proxy. It supports two upstreams: Anthropic API via Claude OAuth tokens, and the chatgpt.com backend (GPT-5.x family) via Codex/OpenAI OAuth tokens. It accepts both OpenAI-compatible and Anthropic-native request formats.

中文说明见 [README_CN.md](README_CN.md).

## What it does

- OpenAI-compatible API: `/v1/chat/completions`, `/v1/responses`, `/v1/models`
- OpenAI Images API: `/v1/images/generations`, `/v1/images/edits` (routed through Codex OAuth)
- Anthropic-native API: `/v1/messages`, `/v1/messages/count_tokens`
- Codex Provider: support for Codex/OpenAI OAuth accounts via `/v1/responses` passthrough to chatgpt.com backend (GPT-5.x family), with full input sanitization (call_id normalization, stale ref cleanup, tool role rewriting)
- Multi-account management with round-robin selection, sticky routing, failure backoff, and automatic refresh
- BasicAuth-protected admin UI for account and API key management
- Two login flows: browser OAuth with PKCE and cookie-based `sessionKey` authorization
- File-based storage: tokens are stored as JSON files and config is stored as YAML, no database required


## Quick start

```bash
mix deps.get
mix run --no-halt
```

If `config.yaml` does not exist, the app starts with defaults and writes a local config file on first use. The server listens on `http://127.0.0.1:8318` by default.

## Before you run it

1. Copy `config.example.yaml` to `config.yaml`
2. Fill in `api-keys` (if left blank, a secure random API key will be auto-generated on startup)
3. Set `admin.username` and `admin.password` if you want to use the admin panel (if left blank or omitted, secure random admin credentials will be auto-generated and printed on first startup)
4. Make sure `auth-dir` points to a writable directory

### Deployment config

If you use the deployment script, copy `scripts/deploy.example.toml` to a private `scripts/deploy.toml` and fill in your real host, key, and cloud settings there. The script still accepts `--config <path.toml>` if you want to keep deployment parameters in another local path.


## Web UI (Admin Panel)

The admin panel at `/admin` is protected by BasicAuth (`admin.username` / `admin.password`) and provides:

- Accounts: add via browser OAuth (PKCE) or `sessionKey`, view status, refresh tokens, remove accounts
- API keys: list/generate/delete proxy API keys used by `/v1/*` endpoints

## Configuration

```yaml
host: "0.0.0.0"
port: 8318

auth-dir: "~/.auth2api_ex"

admin:
  username: "admin"
  password: "change-me"

api-keys:
  - "sk-your-key-here"

body-limit: "200mb"

cloaking:
  cli-version: "2.1.88"
  entrypoint: "cli"

timeouts:
  messages-ms: 120000
  stream-messages-ms: 600000
  count-tokens-ms: 30000

images:
  default-model: "gpt-image-2"
  upstream-codex-model: "gpt-5.4-mini"
  max-image-bytes: 20971520
  max-upload-bytes: 20971520
  pointer-retry-count: 8
  pointer-retry-delay-ms: 750
  edits-oauth-max-n: 1

debug: "off"
```

Keep `config.yaml` on your machine and do not commit it. `config.example.yaml` is the template for public use.

## API endpoints

### Proxy endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/models` | List supported models |
| POST | `/v1/chat/completions` | OpenAI Chat Completions |
| POST | `/v1/responses` | OpenAI Responses API |
| POST | `/v1/images/generations` | OpenAI Images Generation |
| POST | `/v1/images/edits` | OpenAI Images Edit |
| POST | `/v1/messages` | Anthropic Messages API |
| POST | `/v1/messages/count_tokens` | Count tokens |

Example:

```bash
curl http://localhost:8318/v1/chat/completions \
  -H "Authorization: Bearer sk-your-key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "sonnet",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": false
  }'
```

Model aliases: `opus` -> `claude-opus-4-6`, `sonnet` -> `claude-sonnet-4-6`, `haiku` -> `claude-haiku-4-5-20251001`

Codex models: `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, `gpt-5.3-codex-spark`, `gpt-5.2`, etc. (via Codex OAuth accounts, routed through `/v1/responses` passthrough)

### Admin endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/admin` | Admin UI |
| GET | `/admin/api/accounts` | List accounts and status |
| POST | `/admin/api/accounts/cookie-auth` | Add an account via `sessionKey` |
| POST | `/admin/api/accounts/oauth-start` | Start browser OAuth |
| GET | `/admin/api/accounts/oauth-status` | Poll OAuth result |
| POST | `/admin/api/accounts/:email/refresh` | Refresh a token |
| DELETE | `/admin/api/accounts/:email` | Remove an account |
| GET | `/admin/api/keys` | List API keys |
| POST | `/admin/api/keys` | Generate a new key |
| DELETE | `/admin/api/keys/:key` | Delete a key |

### Other

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |

## Architecture

```
.
├── lib/
│   ├── auth2api_ex/
│   │   ├── admin/
│   │   │   ├── handler.ex
│   │   │   └── html.ex
│   │   ├── accounts/
│   │   │   └── manager.ex
│   │   ├── auth/
│   │   │   ├── oauth.ex
│   │   │   ├── cookie_auth.ex
│   │   │   ├── callback_server.ex
│   │   │   ├── pkce.ex
│   │   │   ├── token_data.ex
│   │   │   ├── token_storage.ex
│   │   │   ├── http_client.ex
│   │   │   └── req_http_client.ex
│   │   ├── handlers/
│   │   │   ├── openai.ex
│   │   │   ├── openai_images.ex
│   │   │   └── anthropic.ex
│   │   ├── upstream/
│   │   │   ├── translator.ex
│   │   │   ├── translator/
│   │   │   ├── anthropic_api.ex
│   │   │   ├── codex_api.ex
│   │   │   ├── codex_models.ex
│   │   │   ├── codex_input_filter.ex
│   │   │   ├── cloaking.ex
│   │   │   ├── response_filter.ex
│   │   │   ├── failure_classifier.ex
│   │   │   ├── images/
│   │   │   │   ├── codex.ex
│   │   │   │   └── request.ex
│   │   │   └── streaming.ex
│   │   ├── server.ex
│   │   ├── config.ex
│   │   └── application.ex
│   └── auth2api_ex_cli.ex
├── test/
│   ├── auth2api_ex/
│   │   ├── admin/
│   │   ├── unit_test.exs
│   │   └── streaming_test.exs
│   └── support/
│       └── mocks.ex
└── mix.exs
```

## Design notes

- ETS is used for hot-path reads so `get_next_account` does not need a GenServer call
- Sticky routing keeps a selected account stable for 20 to 60 minutes
- Failure backoff is based on failure kind, for example rate limit versus auth failures
- Tokens are refreshed automatically before expiry
- Each account is persisted as a JSON file under `auth-dir/`, so no database is needed

## Data storage

- Tokens are stored as JSON files in `auth-dir` by default, e.g. `~/.auth2api_ex/`
- Config is kept in a single YAML file
- API keys can be managed through the admin panel or by editing YAML directly

## Testing

```bash
mix test --no-start
```

The test suite uses [Mox](https://github.com/dashbitco/mox) for HTTP client mocking. CookieAuth tests cover the full three-step flow (organizations -> authorize -> token exchange) without contacting real Claude servers.

## Dependencies

| Package | Purpose |
|---------|---------|
| plug / plug_cowboy | HTTP server |
| jason | JSON encoding and decoding |
| yaml_elixir | YAML config parsing |
| req | HTTP client |
| uuid | UUID generation |
| mox | Mocking in tests |


## Reference projects

- AmazingAng/auth2api_ex 
- Wei-Shaw/sub2api


## License

MIT
