# auth2api_ex-elixir

这是一个将 OAuth 授权转换为 API 代理的 Elixir 实现。支持两种上游：使用 Claude OAuth token 转发到 Anthropic API，以及使用 Codex/OpenAI OAuth token 转发到 chatgpt.com 后端（GPT-5.x 系列）。它接受 OpenAI 兼容格式和 Anthropic 原生格式的请求。

English version: [README.md](README.md).

## 功能

- **OpenAI 兼容 API** — `/v1/chat/completions`, `/v1/responses`, `/v1/models`
- **OpenAI Images API** — `/v1/images/generations`, `/v1/images/edits`（通过 Codex OAuth）
- **Anthropic 原生 API** — `/v1/messages`, `/v1/messages/count_tokens`
- **Codex Provider** — 支持 Codex/OpenAI OAuth 账号，通过 `/v1/responses` 直通 chatgpt.com 后端（GPT-5.x 系列模型），含完整的 input 清洗（call_id 修复、stale ref 清理、tool role 规范化）
- **多账户管理** — 轮询（round-robin）并带有粘性选择、失败回退与自动刷新
- **管理面板** — 使用 BasicAuth 保护的 Web UI，用于账户和 API key 管理
- **两种授权方式** — 浏览器 OAuth（PKCE）和基于 `sessionKey` 的 Cookie 自动授权
- **文件存储** — Token 存为 JSON 文件，配置为 YAML，无需数据库

## 快速开始

```bash
mix deps.get
mix run --no-halt
```

如果没有 `config.yaml`，程序会按默认值启动，并在首次使用时写入一个本地配置文件。服务器默认监听在 `http://127.0.0.1:8318`。

## 运行前准备

1. 复制 `config.example.yaml` 为 `config.yaml`
2. 填写 `api-keys`（如果留空，启动时会自动生成一个随机 API 密钥）
3. 如需使用管理面板，配置 `admin.username` 和 `admin.password`（如果留空或缺省，首次启动时会自动生成安全的随机账户密码并打印在启动日志中）
4. 确保 `auth-dir` 指向一个可写目录

### 部署配置

如果你使用部署脚本，先把 `scripts/deploy.example.toml` 复制成私有的 `scripts/deploy.toml`，再填写真实的主机、密钥和云资源配置。脚本仍然支持 `--config <path.toml>`，所以也可以把部署参数放到别的本地路径。


## Web UI（管理面板）

`/admin` 是一个使用 BasicAuth 保护的管理界面（`admin.username` / `admin.password`），主要用于：

- 账户管理：通过浏览器 OAuth（PKCE）或 `sessionKey` 添加账户、查看状态、刷新 token、删除账户
- API key 管理：查看/生成/删除代理服务的 API key（用于 `/v1/*` 接口）

## 配置

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

建议把 `config.yaml` 保持在本机，不要提交到仓库。仓库里提供的 `config.example.yaml` 只作为模板。

## API 端点

### 代理（需要 API key）

| Method | Path | 说明 |
|--------|------|------|
| GET | `/v1/models` | 列出支持的模型 |
| POST | `/v1/chat/completions` | OpenAI Chat Completions 接口 |
| POST | `/v1/responses` | OpenAI Responses API |
| POST | `/v1/images/generations` | 图片生成 |
| POST | `/v1/images/edits` | 图片编辑 |
| POST | `/v1/messages` | Anthropic Messages API |
| POST | `/v1/messages/count_tokens` | 计数 tokens |

示例：

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

模型别名：`opus` → `claude-opus-4-6`，`sonnet` → `claude-sonnet-4-6`，`haiku` → `claude-haiku-4-5-20251001`

Codex 模型：`gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, `gpt-5.3-codex-spark`, `gpt-5.2` 等（通过 Codex OAuth 账号访问，走 `/v1/responses` 直通）

### 管理面板（需要登陆）

| Method | Path | 说明 |
|--------|------|------|
| GET | `/admin` | 管理界面 |
| GET | `/admin/api/accounts` | 列出账户及状态 |
| POST | `/admin/api/accounts/cookie-auth` | 通过 `sessionKey` 添加账户 |
| POST | `/admin/api/accounts/oauth-start` | 启动浏览器 OAuth 流程 |
| GET | `/admin/api/accounts/oauth-status` | 轮询 OAuth 结果 |
| POST | `/admin/api/accounts/:email/refresh` | 刷新 token |
| DELETE | `/admin/api/accounts/:email` | 移除账户 |
| GET | `/admin/api/keys` | 列出 API keys |
| POST | `/admin/api/keys` | 生成新 key |
| DELETE | `/admin/api/keys/:key` | 删除 key |

### 其他

| Method | Path | 说明 |
|--------|------|------|
| GET | `/health` | 健康检查 |

## 架构

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

## 关键设计决策

- **使用 ETS 优化热路径读取** — `get_next_account` 直接从 ETS 读取，无需通过 GenServer 调用
- **粘性选择** — 选定账户后保持粘性，持续 20–60 分钟
- **指数退避** — 根据失败类型设置冷却时间（例如 rate_limit: 基础 1 分钟，auth: 基础 10 分钟）
- **自动刷新** — 在到期前 4 小时刷新 token
- **文件存储** — 每个账户一个 JSON 文件保存在 `auth-dir/`，无需数据库

## 数据存储

**Tokens** — 以 JSON 文件形式保存在 `auth-dir`（默认 `~/.auth2api_ex/`）：

```text
~/.auth2api_ex/
  claude-user@gmail.com.json
  claude-work@corp.com.json
```

**Config** — 使用单个 YAML 文件，首次运行时会自动生成 API key。

**API keys** — 可通过管理面板或直接编辑 YAML 管理。通过管理面板的更改会写回 `config.yaml` 并在内存中热加载。

## 测试

```bash
mix test --no-start
```

使用 [Mox](https://github.com/dashbitco/mox) 对 HTTP client 进行 mocking。CookieAuth 的测试模拟完整的三步流程（organizations → authorize → token exchange），不会访问真实的 Claude 服务器。

## 依赖项

| 包 | 用途 |
|----|------|
| plug / plug_cowboy | HTTP 服务器 |
| jason | JSON 编解码 |
| yaml_elixir | YAML 配置解析 |
| req | HTTP 客户端 |
| uuid | 生成 UUID |
| mox | Mock 框架 |


## 参考项目

- AmazingAng/auth2api 
- Wei-Shaw/sub2api


## 许可证

MIT
