# Codex WebSocket 代理 Spec

> 参考：sub2api `ResponsesWebSocket` + `ProxyResponsesWebSocketFromClient` + `openai_ws_forwarder.go`
> 
> 目标：auth2api_ex 支持 Codex CLI 的 WebSocket 连接代理，解决 `Reconnecting...` 断连问题

---

## 1. 背景

Codex CLI 使用两种协议：
- **HTTP POST** `/codex/responses` — API 调用（已支持）
- **WebSocket** `GET /v1/responses` (Upgrade) — 文件同步 / 长连接

当前 auth2api_ex 只支持 HTTP POST。Codex CLI 的文件操作（`Creating files`/`editing files`）走 WebSocket 直连 chatgpt.com，经常断连报 `Reconnecting...`。

## 2. 端点设计

```
GET /v1/responses
Upgrade: websocket
Authorization: Bearer <api-key>
```

响应：101 Switching Protocols，然后双向 WS 转发。

## 3. 架构流程

```
Codex CLI                  auth2api_ex                    chatgpt.com
    |                           |                              |
    |-- WS Upgrade ------------>|                              |
    |                           |-- 验证 API key               |
    |                           |-- 选择账户                    |
    |                           |-- WS 连接上游 -------------->|
    |                           |                              |
    |-- response.create ------->|-- 转发 --------------------->|
    |<-- response.delta --------|<-- 转发 --------------------<|
    |-- response.create ------->|-- 转发 --------------------->|
    |<-- response.done ---------|<-- 转发 --------------------<|
    |                           |                              |
    |-- close ----------------->|-- close ------------------->|
```

## 4. 接口

### 4.1 入口：WS Upgrade 处理

```elixir
# lib/auth2api_ex/handlers/codex_ws.ex

def handle_upgrade(conn, config) do
  # 1. 验证 API key
  # 2. 获取账户（Manager.get_next_account）
  # 3. 建立上游 WS 连接
  # 4. 双向转发
end
```

### 4.2 上游 WS 连接

连接 `wss://chatgpt.com/backend-api/codex/responses`，携带：
- Headers: Authorization, User-Agent, originator, version
- 和 HTTP 请求相同的 header 集合

### 4.3 双向转发

- **下行**（客户端 → 代理 → 上游）：直接透传 binary/text 帧
- **上行**（上游 → 代理 → 客户端）：直接透传，记录 usage

## 5. 需要修改的文件

| 文件 | 改动 |
|------|------|
| `server.ex` | 新增 `GET /v1/responses` WS upgrade 路由 |
| `handlers/codex_ws.ex` | **新增**：WS 升级处理 + 双向转发 |
| `upstream/codex_ws_client.ex` | **新增**：上游 WS 客户端（连接 chatgpt.com） |
| `accounts/manager.ex` | 可能需要 WS 连接计数 |

## 6. 依赖

需要在 `mix.exs` 添加 WebSocket 客户端库：

```elixir
{:websockex, "~> 0.4"}  # WebSocket 客户端
```

Cowboy 自带 WS 服务端支持（`Plug.Cowboy` 已集成）。

## 7. 风险

- **复杂度**：sub2api 的 WS 实现 1000+ 行，包括重连、错误处理、账户调度
- **连接管理**：WS 是长连接，需要跟踪活跃连接数、防止泄漏
- **上游 WS 库**：Erlang/Elixir 的 WS 客户端生态不如 Go 成熟

## 8. 替代方案

不改代理，让 Codex CLI 直接配 HTTP 模式（`supports_websockets = false`）。如果 HTTP 模式下的文件操作也正常，就不需要 WS 代理。
