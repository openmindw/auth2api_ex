# Observational Memory 在 auth2api_ex 中的处理方案分析

## 1. 两个项目定位的本质差异

| 维度 | Mastra OM | auth2api_ex |
|------|-----------|-------------|
| **角色** | Agent Framework — 直接控制 LLM 调用生命周期 | API Proxy — 透明代理，不控制 Agent 行为 |
| **OM 嵌入点** | `processInputStep` / `processOutputResult` — Agent 内部 | 无 Agent 概念 — 只有 HTTP 请求/响应管道 |
| **消息所有权** | 持有完整 MessageList，可读可写 | 仅透传消息体，按格式翻译 |
| **状态管理** | Node.js 单进程，静态 Map 协调 | BEAM/OTP — GenServer + ETS，天然分布式友好 |

**核心结论：auth2api_ex 无法像 Mastra 那样以 Agent Processor 方式嵌入 OM，但它可以扮演 Mastra 的 Gateway 角色 — 即服务端透明记忆层。**

---

## 2. Mastra OM 架构回顾（对照 auth2api_ex 现有能力映射）

```
Mastra OM 架构                          auth2api_ex 现有对应能力
══════════════════════════════════════  ════════════════════════════════
                                       
Observer Agent (observer-agent.ts)      ❌ 无 — 需要新增 LLM 调用能力
  ↓ 提取结构化观察笔记                    
                                       
Reflector Agent (reflector-agent.ts)    ❌ 无 — 需要新增多级压缩逻辑
  ↓ 压缩观察为反思                        
                                       
Processor (processor.ts)               Server Plug 管线 (server.ex)
  ↓ 生命周期拦截                          ↓ 可在 pipeline 中插入 OM Plug
                                       
BufferingCoordinator                    Accounts.Manager (GenServer + ETS)
  ↓ 静态 Map 协调缓冲状态                  ↓ GenServer 序列化写 + ETS 读
                                       
TokenCounter                            ❌ 可复用 Translator 层的 token 计数
  ↓ 计算 token 数                        
                                       
Message-utils.ts                        SessionKey + Translator
  ↓ 裁剪已观察消息                         ↓ 已有 session/conversation 追踪
                                       
Storage (PG/D1/Dynamo...)              UtilizationStore + ETS
  ↓ DB 持久化                             ↓ 已有的文件/ETS 持久化模式
```

---

## 3. auth2api_ex 中实现 OM 的三种方案

### 方案 A：透明记忆代理（推荐 ⭐）

**原理**：将 OM 作为 Plug 中间件插入 `server.ex` 管线，对上游/下游请求进行透明的上下文注入和消息观察。

```
Client → [API Key Auth] → [OM Plug] → [Handler] → Upstream API
                ↑              ↑            ↑
         session_key    inject obs    translate format
         extraction      into ctx      (OpenAI ↔ Anthropic)
```

**OM Plug 在 Pipeline 中的位置**：

```elixir
# server.ex 当前管线
plug(:put_config)
plug(Auth2ApiEx.Utils.RequestDecompression)
plug(:parse_body)
plug(:cors)
plug(:rate_limit)
plug(:match)     # ← 现在插在这里？不行，match 之后才路由
plug(:dispatch)

# 建议：OM 插入在 handler 内部（更灵活）
# 因为只有 POST /v1/chat/completions 等路由需要 OM
```

**更精确的插入点 — 在 Handler 层**：

```
# handlers/openai.ex 的 handle_chat_completions
def handle_chat_completions(conn, config) do
  body = conn.assigns[:parsed_body]
  messages = body["messages"]
  
  # ── OM Step 1: 注入记忆上下文 ──
  {injected_messages, om_ctx} = OM.inject_context(conn, messages, config)
  
  # ── 翻译 + 上游调用 ──
  translated = Translator.openai_to_anthropic(body |> Map.put("messages", injected_messages))
  # ... 现有逻辑 ...
  
  # ── OM Step 2: 观察新消息 ──
  OM.observe(om_ctx, response_messages)
end
```

**优势**：
- 客户端零改动 — 对使用 auth2api_ex 代理的客户端完全透明
- 复用现有的 session_key 机制做 thread binding
- 不需要独立的 agent 运行环境

**劣势**：
- OM 的 Observer/Reflector LLM 调用会增加代理延迟（可异步化）
- 需要额外管理 OM 的 LLM 调用（消耗额外 token）

---

### 方案 B：独立 OM GenServer 服务

**原理**：将 ObservationalMemory 抽象为独立的 GenServer，通过 `cast` 异步观察，通过 `call` 同步注入上下文。

```elixir
defmodule Auth2ApiEx.ObservationalMemory do
  use GenServer
  
  # 三层状态存储
  # ETS :om_records — 类似 Mastra 的 ObservationalMemoryRecord
  # ETS :om_observations — 中期观察
  # ETS :om_reflections — 长期反思
  
  # API
  def inject_context(thread_id, messages, opts)
  def observe_async(thread_id, messages, response)  # cast — 异步
  def observe_sync(thread_id, messages, response)    # call — 同步
  def reflect(thread_id)                              # 触发压缩
end
```

**线程模型**：

```
                    ┌──────────────┐
  HTTP Request ───▶ │  Handler     │
                    │  │           │
                    │  ├─ OM.inject_context()  ← call (同步，需等待)
                    │  ├─ upstream call
                    │  └─ OM.observe_async()   ← cast (异步，不阻塞)
                    └──────────────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  OM GenServer│
                    │  ├─ Observer │  ← 后台 Task.async
                    │  └─ Reflector│  ← 阈值触发
                    └──────────────┘
```

**优势**：
- GenServer 序列化所有写操作，天然解决 Mastra 的 RMW 竞态问题
- ETS 提供无锁并发读，零性能衰减
- OTP Supervisor 保证容错和重启

**劣势**：
- 需要增加 Observer/Reflector 的 LLM 调用能力（目前 auth2api_ex 没有直接调用 LLM 的逻辑，都是代理转发）

---

### 方案 C：OM 作为独立微服务（Gateway 模式）

**原理**：完全模仿 Mastra 的 Gateway 模式 — 将 OM 剥离为独立服务，auth2api_ex 通过检测标记决定是否本地处理还是转发给 OM Gateway。

```
Client → auth2api_ex → (检测: is_om_gateway?) 
                           ├─ Yes → 转发到 OM Gateway
                           └─ No  → 本地透传
```

**类似 Mastra 的 `isMastraGatewayModel` 检测**：

```elixir
defp is_om_gateway_enabled?(conn) do
  # 检测 header 或配置
  Plug.Conn.get_req_header(conn, "x-om-gateway") != [] or
    Config.om_gateway_enabled?()
end
```

这个方案和当前 auth2api_ex 的定位差异较大，不推荐作为首选。

---

## 4. BEAM/OTP 如何解决 Mastra 的生产瓶颈

报告中指出的 Mastra 生产级问题在 BEAM 上有天然优势：

### 问题 1：静态 Map 进程协调

```typescript
// Mastra — 静态 Map，多实例不可见
static asyncBufferingOps = new Map<string, Promise<void>>();
```

```elixir
# BEAM — ETS 表，所有进程可见 + 分布式复制
:ets.new(:om_buffering_ops, [:set, :public, :named_table, read_concurrency: true])

# 分布式场景下使用 :pg 做集群协调
:pg.join(:om_cluster, node())
```

### 问题 2：RMW 无 CAS 导致数据丢失

```typescript
// Mastra — Read-Modify-Write，Last-Write-Wins
const record = await storage.get(id);
record.observations += newObs;  // 内存修改
await storage.update(record);    // 覆盖写 — 并发丢失！
```

```elixir
# BEAM — GenServer 序列化所有写操作，天然原子性
def handle_call({:add_observation, thread_id, obs}, _from, state) do
  # 所有写操作在 GenServer 邮箱中排队，不存在并发覆盖
  record = Map.get(state.records, thread_id)
  updated = %{record | observations: record.observations <> obs}
  {:reply, :ok, put_in(state.records[thread_id], updated)}
end
```

### 问题 3：无分布式锁

```typescript
// Mastra — 进程内 Promise-based mutex
this.locks = new Map<string, Promise<void>>();
```

```elixir
# BEAM — 天然分布式就绪
# 方案 1: 利用 GenServer 的单进程特性做锁
# 方案 2: 用 :global 或 :pg 做分布式注册
# 方案 3: ETS + :global.trans 做分布式事务
```

---

## 5. 推荐实施方案的详细设计（方案 A）

### 5.1 模块结构

```
lib/auth2api_ex/
├── om/
│   ├── om_server.ex          # GenServer — OM 主进程
│   ├── om_record.ex          # OM Record 结构 + ETS 操作
│   ├── om_config.ex          # 配置：阈值、模型选择
│   ├── om_observer.ex        # Observer Agent — 提取观察
│   ├── om_reflector.ex       # Reflector Agent — 压缩反思
│   ├── om_context.ex         # 上下文注入（plug/handler 中使用）
│   ├── om_token_counter.ex   # Token 计数（复用 Translator 能力）
│   └── om_message_utils.ex   # 消息裁剪、标记管理
```

### 5.2 在 Handler 中的集成点

```elixir
# handlers/openai.ex — handle_chat_completions 改造示意
def handle_chat_completions(conn, config) do
  body = conn.assigns[:parsed_body]
  
  if Config.om_enabled?(config) do
    # ── 记忆注入 ──
    session_key = SessionKey.from_request_or_api_key(conn, body)
    {:ok, enriched_body} = OMContext.inject(conn, body, session_key)
    
    # 正常代理流程（使用 enriched_body）
    do_chat_completions(conn, config, enriched_body, model, 
      after_success: fn upstream, account ->
        # ── 异步观察 ──
        OMServer.observe_async(session_key, body, upstream.body)
      end)
  else
    do_chat_completions(conn, config, body, model)
  end
end
```

### 5.3 观察者/反思者的 LLM 调用

auth2api_ex 目前没有直接调用 LLM 的能力。两种解决思路：

**思路 1：复用现有代理链路**
```elixir
# OM 通过自己的代理路径调用 Anthropic/OpenAI API
def observe_messages(messages) do
  account = Manager.get_next_account(:om_manager)
  AnthropicAPI.call_anthropic_messages(
    body: build_observer_prompt(messages),
    account: account,
    config: om_config()
  )
end
```

**思路 2：使用独立的低成本模型**
```elixir
# 用 haiku 或 Gemini flash 做观察（低 token 成本）
config :auth2api_ex, :om_observer_model, "claude-haiku-4-5-20251001"
```

### 5.4 Token 阈值配置

```yaml
# config.yaml 扩展
observational_memory:
  enabled: true
  scope: thread              # thread | resource
  observer_model: "claude-haiku-4-5-20251001"
  reflector_model: "claude-haiku-4-5-20251001"
  
  observation:
    message_tokens: 30000    # 累积多少未观察 token 后触发观察
    buffer_tokens: 10000     # 异步缓冲阈值（低于此值不触发）
    previous_observer_tokens: 2000  # 保留给 Observer 的上下文窗口
  
  reflection:
    observation_tokens: 40000  # 观察累积多少 token 后触发反思
    compression_level: 1       # 初始压缩级别
```

---

## 6. 实现优先级建议

| 阶段 | 内容 | 复杂度 | 价值 |
|------|------|--------|------|
| **P0** | OM GenServer + ETS 基础设施 | 低 | 架构基础 |
| **P1** | 上下文注入（OMContext.inject） | 低 | 立即可用的记忆增强 |
| **P2** | 异步观察（Observer Agent） | 中 | 核心 OM 能力 |
| **P3** | 反思压缩（Reflector Agent） | 中 | 长期对话记忆 |
| **P4** | 多级压缩策略 | 高 | Token 效率优化 |
| **P5** | 分布式协调（:pg / :syn） | 中 | 水平扩展 |

---

## 7. 关键结论

1. **auth2api_ex 不能做 Mastra 那种 Agent 内嵌 OM**（它没有 Agent 生命周期），但可以做 **Gateway 模式的服务端透明记忆层**。

2. **BEAM/OTP 比 Node.js 更适合 OM 的生产化**：GenServer 天然序列化写、ETS 无锁读、OTP 容错恢复，恰好解决了 Mastra 报告中指出的所有分布式瓶颈。

3. **最大工程挑战**：auth2api_ex 需要获得"自己调用 LLM"的能力来做 Observer/Reflector。目前它只是个纯代理，没有主动发起 LLM 请求的逻辑。这个需要评估对账户池、token 消耗、延迟预算的影响。

4. **最小可行方案**：先从"上下文注入 + 简单阈值裁剪"开始——不引入 Observer/Reflector LLM 调用，仅用规则裁剪旧消息，就能显著降低下游 token 消耗。这在 auth2api_ex 中只需几百行代码。