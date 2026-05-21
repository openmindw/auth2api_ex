defmodule Auth2ApiEx.Admin.HTML do
  @moduledoc false

  @spec render() :: String.t()
  def render do
    ~S"""
    <!DOCTYPE html>
    <html lang="zh-CN">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>auth2api_ex 控制台</title>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&family=Plus+Jakarta+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;600&display=swap');

          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          
          :root {
            /* oklch Harmony Color Palette (Light mode only) */
            --canvas: oklch(0.98 0.005 240);
            --panel: oklch(1 0 0);
            --rail: oklch(0.96 0.005 240);
            --border: oklch(0.92 0.01 240);
            --border-hover: oklch(0.85 0.015 240);
            
            --ink: oklch(0.2 0.015 240);
            --ink-dim: oklch(0.45 0.02 240);
            --ink-faint: oklch(0.65 0.02 240);
            
            --primary: oklch(0.45 0.12 170);
            --primary-hover: oklch(0.38 0.12 170);
            --primary-light: oklch(0.96 0.02 170);
            
            --accent: oklch(0.65 0.15 70);
            --success: oklch(0.6 0.15 140);
            --success-light: oklch(0.97 0.03 140);
            --warning: oklch(0.65 0.15 70);
            --warning-light: oklch(0.97 0.03 70);
            --danger: oklch(0.55 0.18 25);
            --danger-light: oklch(0.97 0.03 25);
            
            --control-bg: oklch(1 0 0);
            --r-sm: 4px;
            --r-md: 6px;
            --r-lg: 8px;
            
            --font-ui: "Plus Jakarta Sans", -apple-system, sans-serif;
            --font-display: "Space Grotesk", sans-serif;
            --font-data: "JetBrains Mono", monospace;
          }

          @keyframes pageLoad {
            from { opacity: 0; transform: translateY(6px); }
            to { opacity: 1; transform: translateY(0); }
          }

          body {
            min-height: 100vh;
            background: var(--canvas);
            color: var(--ink);
            font-family: var(--font-ui);
            font-size: 13px;
            line-height: 1.45;
            -webkit-font-smoothing: antialiased;
            animation: pageLoad 0.3s cubic-bezier(0.16, 1, 0.3, 1) both;
          }

          /* Transition settings */
          button, select, tr, .bar, input, textarea {
            transition: background-color 0.15s ease, border-color 0.15s ease, color 0.15s ease;
          }

          .shell {
            display: grid;
            grid-template-columns: 240px minmax(0, 1fr);
            min-height: 100vh;
          }

          .rail {
            border-right: 1px solid var(--border);
            background: var(--rail);
            padding: 24px 18px;
            display: flex;
            flex-direction: column;
            gap: 24px;
          }

          .brand h1 {
            font-family: var(--font-display);
            font-size: 18px;
            font-weight: 700;
            letter-spacing: -0.02em;
          }

          .brand p {
            color: var(--ink-faint);
            font-family: var(--font-ui);
            font-size: 11px;
            margin-top: 4px;
          }

          .version {
            border: 1px solid var(--border);
            border-radius: var(--r-md);
            padding: 8px 10px;
            color: var(--ink-dim);
            font-family: var(--font-data);
            font-size: 11px;
            background: var(--panel);
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
          }

          .rail-group { display: grid; gap: 8px; }

          .rail-label {
            color: var(--ink-faint);
            font-family: var(--font-display);
            font-size: 10px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: .08em;
          }

          .rail-stat {
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 8px;
            padding: 8px 12px;
            border: 1px solid var(--border);
            border-radius: var(--r-sm);
            background: var(--panel);
          }

          .rail-stat span { color: var(--ink-dim); }

          .rail-stat strong { font-family: var(--font-data); font-weight: 600; color: var(--ink); }

          .content {
            min-width: 0;
            padding: 24px;
            display: grid;
            gap: 20px;
          }

          .topbar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
          }

          .topbar h2 {
            font-family: var(--font-display);
            font-size: 16px;
            font-weight: 700;
            color: var(--ink);
          }

          .actions { display: flex; gap: 8px; flex-wrap: wrap; }

          button, select {
            font-family: var(--font-ui);
            font-size: 12px;
            font-weight: 500;
            border: 1px solid var(--border);
            border-radius: var(--r-sm);
            background: var(--control-bg);
            color: var(--ink-dim);
            padding: 6px 12px;
            line-height: 1.4;
            cursor: pointer;
            outline: none;
          }

          button:hover, select:hover { border-color: var(--border-hover); color: var(--ink); }

          button:focus, select:focus, input:focus, textarea:focus { border-color: var(--primary); }

          button.primary { background: var(--primary); color: #ffffff; border-color: var(--primary); }
          button.primary:hover { background: var(--primary-hover); border-color: var(--primary-hover); }

          button.danger { color: var(--danger); border-color: var(--border); }
          button.danger:hover { background: var(--danger-light); border-color: var(--danger); }

          button:disabled { opacity: .45; cursor: default; }

          /* Honest Borders Ledger Style */
          .ledger {
            display: grid;
            grid-template-columns: 1.5fr repeat(4, minmax(120px, 1fr));
            gap: 16px;
          }

          .ledger-main, .ledger-cell {
            padding: 16px 20px;
            background: var(--panel);
            border: 1px solid var(--border);
            border-radius: var(--r-md);
            display: flex;
            flex-direction: column;
            justify-content: space-between;
          }

          .label {
            color: var(--ink-faint);
            font-family: var(--font-display);
            font-size: 10px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: .08em;
          }

          .big {
            font-family: var(--font-display);
            font-size: 28px;
            font-weight: 700;
            line-height: 1.1;
            margin-top: 6px;
            color: var(--accent);
          }

          .value {
            font-family: var(--font-display);
            font-size: 18px;
            font-weight: 700;
            line-height: 1.15;
            margin-top: 6px;
          }

          .hint { color: var(--ink-faint); font-size: 11px; margin-top: 4px; }

          .grid {
            display: grid;
            grid-template-columns: minmax(0, 1.25fr) minmax(360px, 0.75fr);
            gap: 16px;
          }

          .panel {
            border: 1px solid var(--border);
            border-radius: var(--r-md);
            background: var(--panel);
            overflow: hidden;
          }

          .panel-head {
            min-height: 48px;
            padding: 12px 16px;
            display: flex;
            align-items: center;
            justify-content: space-between;
            border-bottom: 1px solid var(--border);
            gap: 10px;
          }

          .panel-head h3 {
            font-family: var(--font-display);
            font-size: 12px;
            font-weight: 700;
            letter-spacing: .05em;
            text-transform: uppercase;
            color: var(--ink-dim);
          }

          .table-wrap { overflow: auto; }

          table { width: 100%; border-collapse: collapse; font-size: 12px; }

          th {
            text-align: left;
            color: var(--ink-faint);
            font-family: var(--font-display);
            font-size: 10px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: .06em;
            padding: 10px 14px;
            border-bottom: 1px solid var(--border);
            white-space: nowrap;
          }

          td {
            padding: 10px 14px;
            border-bottom: 1px solid var(--border);
            vertical-align: middle;
            color: var(--ink);
          }

          tr:last-child td { border-bottom: none; }

          tbody tr:hover { background: var(--primary-light); }

          .mono { font-family: var(--font-data); }

          .muted { color: var(--ink-faint); }

          .right { text-align: right; }

          /* Status color indicator dot - carrying actual information */
          .pill {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 3px 8px;
            border-radius: 999px;
            font-size: 11px;
            font-weight: 500;
            border: 1px solid transparent;
            font-family: var(--font-ui);
          }

          .pill::before { content:''; width: 6px; height: 6px; border-radius: 50%; background: currentColor; }

          .pill.active { color: var(--success); background: var(--success-light); }
          .pill.cooldown, .pill.refreshing { color: var(--warning); background: var(--warning-light); }
          .pill.error { color: var(--danger); background: var(--danger-light); }

          .limit-stack { display:grid; gap:6px; min-width:120px; }

          .limit-row { display:grid; grid-template-columns:minmax(0,1fr); gap:4px; align-items:center; }

          .limit-label { color:var(--ink-dim); font-family:var(--font-ui); font-size:10px; font-weight: 500; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

          .limit-value { font-family:var(--font-data); font-size:11px; font-weight:600; }

          .limit-meter { grid-column:1 / -1; width:100%; height:4px; background:var(--canvas); border-radius:99px; overflow:hidden; }

          .limit-meter span { display:block; height:100%; background:var(--primary); }

          .limit-meter.warn span { background:var(--warning); }

          .limit-meter.danger span { background:var(--danger); }

          .bar-strip {
            display: flex;
            align-items: end;
            gap: 4px;
            height: 100px;
            padding: 16px;
            border-bottom: 1px solid var(--border);
            background: var(--canvas);
          }

          .bar {
            flex: 1;
            min-width: 4px;
            background: var(--primary);
            border-radius: 2px 2px 0 0;
            opacity: 0.85;
          }

          .bar:hover { opacity: 1; }

          .usage-list { padding: 12px; display: grid; gap: 10px; }

          .model-row {
            display: grid;
            grid-template-columns: minmax(0, 1fr) 86px;
            gap: 12px;
            align-items: center;
          }

          .model-meter { height: 4px; background: var(--canvas); border-radius: 99px; overflow: hidden; margin-top: 6px; }

          .model-meter span { display: block; height: 100%; background: var(--primary); }

          .empty td, .empty-block { color: var(--ink-faint); text-align: center; padding: 24px; }

          .cell-actions { display:flex; gap:6px; justify-content:flex-end; }

          /* dialog with modern backdrop blur and slide animation */
          dialog {
            border: 1px solid var(--border);
            border-radius: var(--r-md);
            background: var(--panel);
            color: var(--ink);
            width: min(520px, 92vw);
            padding: 0;
            margin: auto;
            box-shadow: 0 16px 40px rgba(0, 0, 0, 0.08);
          }

          dialog[open] {
            position: fixed;
            inset: 50% auto auto 50%;
            transform: translate(-50%, -50%);
            animation: dialogAppear 0.2s cubic-bezier(0.16, 1, 0.3, 1) both;
          }

          dialog::backdrop {
            background: rgba(15, 23, 42, 0.3);
            backdrop-filter: blur(4px);
          }

          @keyframes dialogAppear {
            from { opacity: 0; transform: translate(-50%, -46%) scale(0.97); }
            to { opacity: 1; transform: translate(-50%, -50%) scale(1); }
          }

          .dialog-head, .dialog-foot {
            padding: 14px 18px;
            display:flex;
            align-items:center;
            justify-content:space-between;
            border-bottom:1px solid var(--border);
            gap: 8px;
          }

          .dialog-foot { border-top:1px solid var(--border); border-bottom:none; justify-content:flex-end; }

          .dialog-body { padding: 18px; display:grid; gap: 12px; }

          .tabs { display:flex; border-bottom:1px solid var(--border); padding:0 18px; }

          .tabs button {
            border:0;
            border-bottom:2px solid transparent;
            border-radius:0;
            background:transparent;
            padding:12px 16px;
            font-weight: 600;
            color: var(--ink-dim);
          }

          .tabs button.active { color:var(--primary); border-bottom-color:var(--primary); }

          .tab-panel { display:none; }

          .tab-panel.active { display:grid; gap:12px; }

          input, textarea {
            width:100%;
            background:var(--canvas);
            border:1px solid var(--border);
            border-radius:var(--r-sm);
            color:var(--ink);
            font-family:var(--font-data);
            font-size:12px;
            padding:10px;
            outline:none;
          }

          textarea { min-height:80px; resize:vertical; }

          .help { color:var(--ink-dim); font-size:12px; line-height: 1.5; }

          .err-msg { color:var(--danger); font-size:12px; display:none; }

          #toast {
            position:fixed;
            right:24px;
            bottom:24px;
            z-index:9999;
            background:var(--panel);
            border:1px solid var(--border);
            border-radius:var(--r-sm);
            padding:10px 16px;
            color:var(--ink);
            font-weight: 500;
            box-shadow: 0 8px 24px rgba(0, 0, 0, 0.06);
            opacity:0;
            transform:translateY(6px);
            transition: opacity 0.15s ease, transform 0.15s ease;
            pointer-events:none;
          }

          #toast.visible { opacity:1; transform:translateY(0); }

          @media (max-width: 980px) {
            .shell { grid-template-columns: 1fr; }
            .rail { border-right:0; border-bottom:1px solid var(--border); }
            .ledger { grid-template-columns: repeat(2, 1fr); }
            .ledger-main { grid-column: 1 / -1; }
            .grid { grid-template-columns: 1fr; }
          }
        </style>
      </head>
      <body>
        <div class="shell">
          <aside class="rail">
            <div class="brand">
              <h1>auth2api_ex</h1>
              <p>个人 OAuth 代理</p>
            </div>
            <div class="version" id="versionBadge">版本加载中...</div>
            <div class="rail-group">
              <div class="rail-label">控制面板</div>
              <div class="rail-stat"><span>账号数</span><strong id="railAccounts">0</strong></div>
              <div class="rail-stat"><span>API 密钥</span><strong id="railKeys">0</strong></div>
              <div class="rail-stat"><span>模型数</span><strong id="railModels">0</strong></div>
            </div>
            <div class="rail-group">
              <div class="rail-label">缓存</div>
              <div class="rail-stat"><span>已读</span><strong id="railCacheRead">0</strong></div>
              <div class="rail-stat"><span>命中率</span><strong id="railCacheHit">0%</strong></div>
            </div>
          </aside>
          <main class="content">
            <div class="topbar">
              <h2>账号、用量、缓存和最近请求</h2>
              <div class="actions">
                <button id="refreshAllBtn">刷新全部</button>
              </div>
            </div>

            <section class="ledger">
              <div class="ledger-main">
                <div class="label">Token 总消耗量</div>
                <div class="big" id="usageTotalTokens">0</div>
                <div class="hint">输入 + 输出 + 缓存创建 + 缓存读取</div>
              </div>
              <div class="ledger-cell"><div class="label">今日消耗</div><div class="value" id="usageTodayTokens">0</div><div class="hint">今日滚动额度</div></div>
              <div class="ledger-cell"><div class="label">成功请求</div><div class="value" id="usageRequests">0</div><div class="hint">成功请求次数</div></div>
              <div class="ledger-cell"><div class="label">缓存读取</div><div class="value" id="usageCacheRead">0</div><div class="hint" id="usageCacheHit">0% 命中率</div><div class="hint" id="usageProviderCacheHit">Claude 0% · Codex 0%</div></div>
              <div class="ledger-cell"><div class="label">活跃账号</div><div class="value" id="usageAccounts">0</div><div class="hint">所有服务商</div></div>
            </section>

            <section class="grid">
              <div class="panel">
                <div class="panel-head">
                  <h3>账号管理</h3>
                  <div class="actions">
                    <button id="refreshAccountsBtn">刷新</button>
                    <button class="primary" id="openAddAccountBtn">添加账号</button>
                  </div>
                </div>
                <div class="table-wrap">
                  <table>
                    <thead><tr><th>邮箱</th><th>服务商</th><th>状态</th><th>用量 / 额度</th><th>过期时间</th><th class="right">成功</th><th class="right">失败</th><th></th></tr></thead>
                    <tbody id="accountsTableBody"><tr class="empty"><td colspan="8">暂无账号</td></tr></tbody>
                  </table>
                </div>
              </div>

              <div class="panel">
                <div class="panel-head"><h3>30 天 Token 消耗趋势</h3><button id="refreshUsageBtn">刷新</button></div>
                <div class="bar-strip" id="usageBars"></div>
                <div class="usage-list" id="modelUsageList"><div class="empty-block">暂无 Token 消耗数据</div></div>
              </div>
            </section>

            <section class="grid">
              <div class="panel">
                <div class="panel-head">
                  <h3>请求日志</h3>
                  <div class="actions">
                    <select id="logStatusFilter"><option value="all">全部</option><option value="2xx">2xx</option><option value="4xx">4xx</option><option value="5xx">5xx</option></select>
                    <button id="refreshLogsBtn">刷新</button>
                    <button class="danger" id="clearLogsBtn">清空</button>
                  </div>
                </div>
                <div class="table-wrap">
                  <table>
                    <thead><tr><th>时间</th><th>路径</th><th>模型</th><th class="right">状态</th><th class="right">耗时(ms)</th><th class="right">Token数</th><th>错误信息</th></tr></thead>
                    <tbody id="logsTableBody"><tr class="empty"><td colspan="7">暂无日志</td></tr></tbody>
                  </table>
                </div>
              </div>

              <div class="panel">
                <div class="panel-head">
                  <h3>API 密钥管理</h3>
                  <div class="actions"><button id="refreshKeysBtn">刷新</button><button class="primary" id="createKeyBtn">生成</button></div>
                </div>
                <div class="table-wrap">
                  <table>
                    <thead><tr><th>密钥</th><th></th></tr></thead>
                    <tbody id="keysTableBody"><tr class="empty"><td colspan="2">暂无密钥</td></tr></tbody>
                  </table>
                </div>
              </div>
            </section>
          </main>
        </div>

        <dialog id="addAccountDialog">
          <div class="dialog-head">
            <strong>添加账号</strong>
            <div class="actions">
              <select id="providerSelect"><option value="anthropic">Anthropic</option><option value="codex">Codex</option></select>
              <button id="closeDialogBtn">×</button>
            </div>
          </div>
          <div class="tabs"><button data-tab="oauth" class="active">OAuth 授权</button><button data-tab="cookie">SessionKey 登录</button></div>
          <div class="dialog-body">
            <section data-tab-panel="oauth" class="tab-panel active">
              <div id="oauthStep1">
                <p class="help">生成授权链接，登录后粘贴回调代码或完整的回调 URL。</p>
                <div class="dialog-foot"><button id="cancelOauthBtn">取消</button><button class="primary" id="generateUrlBtn">生成 URL</button></div>
              </div>
              <div id="oauthStep2" style="display:none">
                <p class="help">授权 URL</p>
                <div style="display:flex;gap:6px"><input id="oauthUrlInput" readonly /><button id="copyUrlBtn">复制</button></div>
                <p class="help">粘贴 Code 或完整的回调 URL</p>
                <textarea id="oauthCodeInput"></textarea>
                <div class="err-msg" id="oauthError"></div>
                <div class="dialog-foot"><button id="cancelOauthStep2Btn">取消</button><button class="primary" id="exchangeCodeBtn">完成</button></div>
              </div>
            </section>
            <section data-tab-panel="cookie" class="tab-panel">
              <p class="help">仅适用于 Anthropic SessionKey。Codex 请使用 OAuth 授权。</p>
              <textarea id="sessionKeyInput" placeholder="sk-session-..."></textarea>
              <div class="dialog-foot"><button id="cancelCookieBtn">取消</button><button class="primary" id="submitCookieBtn">确认添加</button></div>
            </section>
          </div>
        </dialog>

        <dialog id="customKeyDialog">
          <div class="dialog-head">
            <strong>生成 API 密钥</strong>
            <button id="closeCustomKeyDialogBtn">×</button>
          </div>
          <div class="dialog-body">
            <p class="help">可以指定所需的 API 密钥字符，留空则自动生成高强度随机密钥。</p>
            <input type="text" id="customKeyInput" placeholder="自定义密钥 (例如 sk-custom-12345)" />
            <div class="dialog-foot">
              <button id="cancelCustomKeyBtn">取消</button>
              <button class="primary" id="confirmCustomKeyBtn">确认生成</button>
            </div>
          </div>
        </dialog>

        <div id="toast"></div>
        <script>
          const state = { oauthSessionId: null, currentProvider: 'anthropic' };
          const $ = (id) => document.getElementById(id);
          const fmt = (n) => Intl.NumberFormat('zh-CN', { notation: n >= 100000 ? 'compact' : 'standard' }).format(n || 0);
          const pct = (r) => Math.round((r || 0) * 100) + '%';
          const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

          async function request(url, opts = {}) {
            const res = await fetch(url, { credentials: 'same-origin', headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) }, ...opts });
            const ct = res.headers.get('content-type') || '';
            const body = ct.includes('application/json') ? await res.json() : await res.text();
            if (!res.ok) throw new Error(typeof body === 'string' ? body : (body.error || body.message || '错误'));
            return body;
          }
          function toast(msg) { const t = $('toast'); t.textContent = msg; t.classList.add('visible'); clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.remove('visible'), 2200); }
          
          function statusText(s) {
            const mapping = {
              'active': '活跃',
              'cooldown': '冷却',
              'refreshing': '刷新中',
              'error': '错误'
            };
            return mapping[s] || s;
          }
          
          function statusPill(s) { return '<span class="pill ' + esc(s) + '">' + esc(statusText(s)) + '</span>'; }
          function expires(a) { return '<div class="mono">' + esc(a.expires_in_human || '-') + '</div><div class="muted">' + esc((a.expires_at || '').slice(0,10)) + '</div>'; }
          function usagePct(v) {
            if (v === null || v === undefined || Number.isNaN(Number(v))) return '-';
            const n = Number(v);
            return (Math.round(n * 10) / 10).toString().replace(/\.0$/, '') + '%';
          }
          function meterClass(v) {
            const n = Number(v);
            if (!Number.isFinite(n)) return '';
            if (n >= 90) return 'danger';
            if (n >= 70) return 'warn';
            return '';
          }
          function meterWidth(v) {
            const n = Number(v);
            return Number.isFinite(n) ? Math.max(0, Math.min(100, n)) : 0;
          }
          function usageLimit(a, key, label, resetKey) {
            const v = a[key];
            const reset = a[resetKey] || '未采样';
            const title = a[resetKey] ? label + ' 将在 ' + a[resetKey] + ' 后重置' : label + ' 未采样';
            return '<div class="limit-row" title="' + esc(title) + '"><span class="limit-label">' + esc(label) + ' · ' + usagePct(v) + ' · ' + esc(reset) + '</span><div class="limit-meter ' + meterClass(v) + '"><span style="width:' + meterWidth(v) + '%"></span></div></div>';
          }
          function usageLimits(a) {
            return '<div class="limit-stack">' + usageLimit(a, 'utilization_5h', '5小时', 'reset_5h_human') + usageLimit(a, 'utilization_7d', '周额度', 'reset_7d_human') + '</div>';
          }
          function renderAccount(a) {
            return '<tr><td class="mono">' + esc(a.email) + '</td><td class="muted">' + esc(a.provider || 'anthropic') + '</td><td>' + statusPill(a.status) + '</td><td>' + usageLimits(a) + '</td><td>' + expires(a) + '</td><td class="right mono" style="color:var(--success)">' + fmt(a.success_count) + '</td><td class="right mono" style="color:var(--danger)">' + fmt(a.failure_count) + '</td><td><div class="cell-actions"><button data-provider="' + encodeURIComponent(a.provider || 'anthropic') + '" data-refresh="' + encodeURIComponent(a.email) + '">刷新</button><button class="danger" data-provider="' + encodeURIComponent(a.provider || 'anthropic') + '" data-delete="' + encodeURIComponent(a.email) + '">删除</button></div></td></tr>';
          }
          function renderKey(k) {
            return '<tr><td class="mono">' + esc(k.masked) + '</td><td><div class="cell-actions"><button data-copy="' + esc(k.key) + '">复制</button><button class="danger" data-delete-key="' + esc(k.key) + '">删除</button></div></td></tr>';
          }
          function renderLog(l) {
            const tokens = (l.input_tokens || 0) + (l.output_tokens || 0);
            const statusColor = l.status >= 500 ? 'var(--danger)' : l.status >= 400 ? 'var(--warning)' : 'var(--success)';
            return '<tr><td class="muted">' + esc((l.timestamp || '').replace('T',' ').slice(5,19)) + '</td><td class="mono">' + esc(l.path || '-') + '</td><td class="mono">' + esc(l.model || '-') + '</td><td class="right mono" style="color:' + statusColor + '">' + esc(l.status || '-') + '</td><td class="right mono muted">' + esc(l.duration_ms || '-') + '</td><td class="right mono muted">' + (tokens || '-') + '</td><td class="muted" title="' + esc(l.error || '') + '">' + esc((l.error || '').slice(0,54)) + '</td></tr>';
          }
          async function loadAccounts() {
            const d = await request('/admin/api/accounts');
            $('railAccounts').textContent = d.account_count || 0;
            $('usageAccounts').textContent = d.account_count || 0;
            $('accountsTableBody').innerHTML = d.accounts.length ? d.accounts.map(renderAccount).join('') : '<tr class="empty"><td colspan="8">暂无账号</td></tr>';
          }
          async function loadKeys() {
            const d = await request('/admin/api/keys');
            $('railKeys').textContent = d.keys.length || 0;
            $('keysTableBody').innerHTML = d.keys.length ? d.keys.map(renderKey).join('') : '<tr class="empty"><td colspan="2">暂无密钥</td></tr>';
          }
          async function loadUsage() {
            const d = await request('/admin/api/usage');
            const s = d.summary || {};
            $('usageTotalTokens').textContent = fmt(s.total_tokens);
            $('usageTodayTokens').textContent = fmt(s.today_tokens);
            $('usageRequests').textContent = fmt(s.requests);
            $('usageCacheRead').textContent = fmt(s.cache_read_tokens);
            $('usageCacheHit').textContent = pct(s.cache_hit_ratio) + ' 命中率';
            const pb = s.provider_breakdown || {};
            const claude = pb.anthropic || {};
            const codex = pb.codex || {};
            $('usageProviderCacheHit').textContent = 'Claude ' + pct(claude.cache_hit_ratio) + ' · Codex ' + pct(codex.cache_hit_ratio);
            $('railCacheRead').textContent = fmt(s.cache_read_tokens);
            $('railCacheHit').textContent = pct(s.cache_hit_ratio);
            $('railModels').textContent = s.model_count || 0;
            renderBars(d.daily || []);
            renderModelUsage(d.totals || []);
          }
          function renderBars(rows) {
            const byDate = new Map();
            rows.forEach(r => byDate.set(r.date, (byDate.get(r.date) || 0) + (r.total_tokens || 0)));
            const days = [];
            const now = new Date();
            for (let i = 29; i >= 0; i--) { const d = new Date(now); d.setDate(now.getDate() - i); days.push(d.toISOString().slice(0,10)); }
            const vals = days.map(d => byDate.get(d) || 0);
            const max = Math.max(...vals, 1);
            $('usageBars').innerHTML = vals.map((v, i) => '<div class="bar" title="' + days[i] + ' · 消耗 ' + fmt(v) + ' Tokens" style="height:' + Math.max(4, Math.round(v / max * 68)) + 'px"></div>').join('');
          }
          function renderModelUsage(rows) {
            if (!rows.length) { $('modelUsageList').innerHTML = '<div class="empty-block">暂无 Token 消耗数据</div>'; return; }
            const max = Math.max(...rows.map(r => r.total_tokens || 0), 1);
            $('modelUsageList').innerHTML = rows.sort((a,b) => (b.total_tokens||0)-(a.total_tokens||0)).slice(0,8).map(r => '<div class="model-row"><div><div class="mono">' + esc(r.model) + '</div><div class="hint">' + esc(r.email) + ' · 缓存读取 ' + fmt(r.cache_read_input_tokens) + '</div><div class="model-meter"><span style="width:' + Math.round((r.total_tokens || 0) / max * 100) + '%"></span></div></div><div class="right mono">' + fmt(r.total_tokens) + '</div></div>').join('');
          }
          async function loadLogs() {
            const d = await request('/admin/api/logs?limit=80&status=' + $('logStatusFilter').value);
            $('logsTableBody').innerHTML = d.logs.length ? d.logs.map(renderLog).join('') : '<tr class="empty"><td colspan="7">暂无日志</td></tr>';
          }
          async function loadVersion() {
            try { const v = await request('/admin/api/version'); $('versionBadge').innerHTML = 'v' + v.version + ' · ' + v.git_commit + ' · <a href="https://github.com/openmindw/auth2api_ex" target="_blank" style="color:#58a6ff;text-decoration:none">GitHub ⬈</a>'; $('versionBadge').title = JSON.stringify(v, null, 2); } catch(_) { $('versionBadge').textContent = '版本未知'; }
          }
          async function refreshAll() { try { await Promise.all([loadAccounts(), loadKeys(), loadUsage(), loadLogs(), loadVersion()]); } catch(e) { toast(e.message); } }
          async function submitCustomKey() {
            const key = $('customKeyInput').value.trim();
            try {
              const d = await request('/admin/api/keys', { method:'POST', body: JSON.stringify({ key: key }) });
              await navigator.clipboard.writeText(d.key);
              toast('密钥已生成并复制到剪贴板');
              $('customKeyDialog').close();
              loadKeys();
            } catch(e) {
              toast(e.message);
            }
          }
          async function submitSessionKey() { const v = $('sessionKeyInput').value.trim(); if (!v) return toast('请粘贴 SessionKey'); try { await request('/admin/api/accounts/cookie-auth', { method:'POST', body:JSON.stringify({ session_key:v, provider:state.currentProvider }) }); $('sessionKeyInput').value=''; $('addAccountDialog').close(); toast('账号添加成功'); loadAccounts(); } catch(e) { toast(e.message); } }
          function resetOauth() { $('oauthStep1').style.display=''; $('oauthStep2').style.display='none'; $('oauthUrlInput').value=''; $('oauthCodeInput').value=''; $('oauthError').style.display='none'; state.oauthSessionId=null; }
          async function generateOauthUrl() { try { const d = await request('/admin/api/accounts/oauth-start', { method:'POST', body:JSON.stringify({ provider:state.currentProvider }) }); state.oauthSessionId=d.session_id; $('oauthUrlInput').value=d.auth_url; $('oauthStep1').style.display='none'; $('oauthStep2').style.display=''; } catch(e) { toast(e.message); } }
          async function exchangeOauthCode() { const code = $('oauthCodeInput').value.trim(); if (!code || !state.oauthSessionId) return toast('缺少授权码'); try { const d = await request('/admin/api/accounts/oauth-exchange', { method:'POST', body:JSON.stringify({ session_id:state.oauthSessionId, code }) }); $('addAccountDialog').close(); toast('OAuth 授权成功: ' + d.email); loadAccounts(); } catch(e) { $('oauthError').textContent=e.message; $('oauthError').style.display='block'; } }

          $('openAddAccountBtn').onclick = () => { resetOauth(); $('addAccountDialog').showModal(); };
          $('closeDialogBtn').onclick = () => $('addAccountDialog').close();
          $('cancelOauthBtn').onclick = () => $('addAccountDialog').close();
          $('cancelOauthStep2Btn').onclick = () => $('addAccountDialog').close();
          $('cancelCookieBtn').onclick = () => $('addAccountDialog').close();
          $('refreshAllBtn').onclick = refreshAll;
          $('refreshAccountsBtn').onclick = loadAccounts;
          $('refreshKeysBtn').onclick = loadKeys;
          $('refreshUsageBtn').onclick = loadUsage;
          $('refreshLogsBtn').onclick = loadLogs;
          $('createKeyBtn').onclick = () => { $('customKeyInput').value = ''; $('customKeyDialog').showModal(); };
          $('cancelCustomKeyBtn').onclick = () => $('customKeyDialog').close();
          $('closeCustomKeyDialogBtn').onclick = () => $('customKeyDialog').close();
          $('confirmCustomKeyBtn').onclick = submitCustomKey;
          $('submitCookieBtn').onclick = submitSessionKey;
          $('generateUrlBtn').onclick = generateOauthUrl;
          $('copyUrlBtn').onclick = async () => { await navigator.clipboard.writeText($('oauthUrlInput').value); toast('已复制'); };
          $('exchangeCodeBtn').onclick = exchangeOauthCode;
          $('logStatusFilter').onchange = loadLogs;
          $('providerSelect').onchange = function() { state.currentProvider = this.value; document.querySelector('[data-tab="cookie"]').style.display = this.value === 'codex' ? 'none' : ''; document.querySelector('[data-tab="oauth"]').click(); resetOauth(); };
          $('oauthCodeInput').oninput = function() { const v = this.value.trim(); try { const u = new URL(v); const c = u.searchParams.get('code'); if (c) this.value = c; } catch(_) { const m = v.match(/[?&]code=([^&]+)/); if (m) this.value = m[1]; } };
          document.querySelectorAll('[data-tab]').forEach(btn => btn.onclick = () => { document.querySelectorAll('[data-tab]').forEach(b => b.classList.toggle('active', b === btn)); document.querySelectorAll('[data-tab-panel]').forEach(p => p.classList.toggle('active', p.dataset.tabPanel === btn.dataset.tab)); });
          document.addEventListener('click', async e => {
            const t = e.target;
            try {
              if (t.dataset.refresh) { await request('/admin/api/accounts/' + t.dataset.refresh + '/refresh?provider=' + encodeURIComponent(t.dataset.provider || 'anthropic'), { method:'POST', body:'{}' }); toast('正在刷新...'); loadAccounts(); }
              if (t.dataset.delete) { await request('/admin/api/accounts/' + t.dataset.delete + '?provider=' + encodeURIComponent(t.dataset.provider || 'anthropic'), { method:'DELETE' }); toast('已删除'); loadAccounts(); }
              if (t.dataset.deleteKey) { await request('/admin/api/keys/' + encodeURIComponent(t.dataset.deleteKey), { method:'DELETE' }); toast('密钥已删除'); loadKeys(); }
              if (t.dataset.copy) { await navigator.clipboard.writeText(t.dataset.copy); toast('已复制'); }
            } catch(err) { toast(err.message); }
          });
          $('clearLogsBtn').onclick = async () => { try { await request('/admin/api/logs', { method:'DELETE' }); toast('日志已清空'); loadLogs(); } catch(e) { toast(e.message); } };
          refreshAll();
        </script>
      </body>
    </html>
    """
  end
end
