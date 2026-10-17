# SLOT GAMES 合集 — 开发任务说明（需求补全版 v1）

> 目标（保持原意图不变）：把现有的老虎机项目扩展为**多款 SLOT 游戏的合集**，并让**多主题机台共用同一套 CONFIG 引擎**。
> 本文在原始需求基础上补全了：功能范围、约束条件、实现方向、文件结构、依赖、MCP 集成步骤、稳定性要求与前端交互定义。
>
> 适用读者：开发 / 评审 / 部署人员。文中 `【待确认】` 标记的条目为开放问题，需在 M1 启动前拍板。

---

## 0. 现状核查与前提（先读这一节）

| 核查项 | 结果 |
| --- | --- |
| 工作区 `c:/Users/Administrator/CodeBuddy/20261017224525` | 仅 `free-auto-gateway.ps1`（本地 LLM 网关脚本），**无任何游戏代码** |
| 已部署游戏 / 现有老虎机项目 | **未找到**（工作区及 `~/CodeBuddy` 下无相关目录） |
| 名为 "Blender" 的 MCP 服务 | **未找到**（本机 MCP 配置中无 blender 条目；可用的是 CloudBase 系列 MCP 工具） |
| 可用的运行时 / 部署通道 | Node 20+；如需上云，可用 CloudBase（静态托管 / 云函数 / 数据库） |

### 由此产生的关键假设（如与实际不符请指出，我会据此改写）

- **A1**：所谓 "Blender MCP" 指的是**承载游戏的 MCP 服务层**（即对外暴露 `slot.*` 工具的 MCP Server），而不是 Blender 3D 建模工具。引擎与 MCP 传输层解耦，同一套引擎可同时以 stdio / HTTP 两种 transport 暴露。
- **A2**："现有老虎机项目" 如果确实存在于其它路径，请先告知路径；本说明按 **引擎 + 主题包从零落地** 编写，同时保留"接入既有 monorepo"的集成章节（见 §7.3）。
- **A3**：游戏为**娱乐积分制**（虚拟币），不涉及真钱交易、不涉及法定博彩牌照。所有数值为演示用途。
- **A4**：目标语言 TypeScript，运行时 Node 20+，包管理 pnpm workspace。

---

## 1. 概念模型（统一词汇，避免后续歧义）

```
CONFIG 引擎 (Engine)  ── 与主题无关：RNG、卷轴采样、赢线求值、特性状态机、账本
        │
        ├── 主题包 (Theme Pack) ── 纯数据：reels / symbols / paytable / features / rtp / assets / uiHints
        │        ├── fruit-classic-3x3
        │        ├── book-of-pharaoh-5x3
        │        └── mega-ways-lite-6x4
        │
        ├── 注册表 (Registry) ── gameId → ThemeConfig，统一入口 createGame(gameId, overrides)
        │
        ├── 适配层 (MCP Server) ── tools: slot.list_games / slot.spin / ...
        │
        └── 前端机台 (Web Cabinet) ── 同一套组件，换 config 即换皮肤与玩法
```

- **核心原则**：`engine` 里**不允许出现任何主题名、符号名、具体赔率数字**。新增一款游戏的成本 = **新增一个 config 文件 + 资源清单 + 一条注册表记录**。

---

## 2. 功能范围（MoSCoW）

### 2.1 Must（M1–M3 必须交付）

**引擎层（engine）**
1. 可复现 RNG：`serverSeed + clientSeed + nonce` → HMAC-SHA256 流式取数，支持事后验算。
2. 卷轴采样（reel strips / weighted reels 两种模式）+ 可选 `forceResult`（测试用）。
3. 中奖判定：`paylines`（固定/可选线）与 `ways`（243/1024/46656）两种求值器；支持 `bothDirections`（如 243 ways 从左到右）。
4. 符号能力矩阵（全部由 config 开关驱动）：
   - `WILD`（ substitutes，可配置 `substitutesExcept`、`wildMultiplier`）
   - `SCATTER`（任意位置计数触发，可配置 `minCount`、`scatterPays`）
   - `BONUS`（独立触发 bonus 小游戏）
   - `EXPANDING` / `STICKY` / `COIN(collect)` / `MULTIPLIER`
5. 特性状态机：`FREE_SPINS`（可重触发 retrigger、递增倍率、expanding 选符号）、`RESPIN`（tumble / cascading）、`HOLD_AND_SPIN`、`PICK_BONUS`、`BONUS_BUY`（可选开关）。
6. 账本与结算：`bet = lineBet × lines × betMultiplier`；`win` 累加；`credit` 变更以**事务**写入，禁止浮点（内部用整数最小单位）。
7. 配置校验器 `validateConfig`：schema 校验 + **理论 RTP 解析计算**（穷举或蒙特卡洛），偏差超阈值直接拒绝加载。
8. 仿真器 `simulate`：`{gameId, spins, seed}` → 实测 RTP、命中率、最大回撤、波动率、特性触发间隔。

**主题层（本周新增热门机台，至少 1 款，建议 3 款）**

| gameId | 主题 | 布局 | 核心机制 | 目标 RTP | 波动 |
| --- | --- | --- | --- | --- | --- |
| `fruit-classic-3x3` | 经典水果机 | 3×3 / 5 固定线 | 7=Wild 三连大奖、Scatter 铃铛触发 10 次免费旋转（含 2× 倍率） | 96.10% | 低 |
| `book-of-pharaoh-5x3` | 埃及探秘（Book系） | 5×3 / 10 线 | Book=Wild+Scatter，3+ 触发 10 次免费旋转并随机选 1 个 expanding symbol；可 retrigger | 96.20% | 高 |
| `mega-ways-lite-6x4` | 宝石矿洞（Ways 系） | 6×4 / 最高 46656 ways | Cascading（消除下落）+ 连击递增倍率（1×/2×/3×…上限 10×）+ 4+ Scatter 触发免费旋转 | 96.50% | 高 |

> **M1 交付下限**：`fruit-classic-3x3` 全链路打通（config → engine → MCP → 前端）。另两款在 M2/M3 以"只加 config"的方式验证引擎通用性——这是检验"共用同一套 CONFIG 引擎"是否成立的**核心验收点**。

**统一入口**
- 单入口 `createGame(gameId, overrides?)`；`overrides` 支持按环境/运营调参（`rtpProfile`、`betLevels`、`featureEnabled`、`denomination`），无需改代码。
- 统一响应 envelope：
  ```jsonc
  { "ok": true, "data": { /* payload */ }, "error": null,
    "meta": { "requestId": "...", "sessionId": "...", "engineVersion": "1.0.0", "configVersion": "1.0.0", "latencyMs": 12 } }
  ```
- 统一错误码：`CONFIG_NOT_FOUND` / `CONFIG_INVALID` / `INVALID_BET` / `INSUFFICIENT_CREDIT` / `SESSION_NOT_FOUND` / `SESSION_EXPIRED` / `SPIN_IN_FLIGHT` / `ENGINE_TIMEOUT` / `INTERNAL`。

**MCP 适配层**
- `slot.list_games`、`slot.get_config`、`slot.validate_config`、`slot.create_session`、`slot.spin`、`slot.get_state`、`slot.end_session`、`slot.simulate`、`slot.verify_spin`（按 seed 复算，用于审计/客诉）。

### 2.2 Should
- 前端大厅（机台卡片网格 + 搜索/筛选/收藏）+ 机台页完整交互。
- 审计日志：每次 spin 落 `{spinId, seed, bet, 结果摘要, 前后 credit}`，可导出。
- 运营配置热更新（config 版本号 + 灰度开关）。
- 本地化（zh-CN / en-US 文案由 config 提供）。

### 2.3 Could
- 排行榜、每日任务、成就；Jackpot 池（固定/累积）；Demo 模式与真实模式切换。

### 2.4 Won't（本次明确不做）
- 真钱支付、KYC、提现；跨机台共享钱包（本期每机台独立 credit，由上层钱包服务聚合）。

---

## 3. 约束条件（硬约束 + 非功能需求）

| 类别 | 约束 |
| --- | --- |
| 正确性 | 实测 RTP 与配置目标偏差 ≤ **0.5%**（100 万次仿真）；所有赔付路径有单元测试 |
| 确定性 | 相同 `(serverSeed, clientSeed, nonce, configVersion)` 必得相同结果；`verify_spin` 可复现 |
| 性能 | 单次 spin 引擎计算 P95 < **50ms**（不含动画）；`simulate` 100 万次 < 60s（可 worker 并行） |
| 数值 | 金额一律 **整数最小单位**（分/积分），禁止浮点累加 |
| 并发 | 每 session 串行：同一 `sessionId` 并发 spin 直接返回 `SPIN_IN_FLIGHT`（幂等键 `requestId`） |
| 状态 | 引擎核心**无状态**（输入 state → 输出 state）；会话状态由适配层持久化，进程重启可恢复 |
| 安全 | 客户端**不可**指定中奖结果或 seed 中的决定性字段（clientSeed 仅参与混合，服务端 seed 为主导）；配置读取走白名单目录，禁止任意路径 |
| 合规 | 纯娱乐积分；UI 显著位置展示"虚拟娱乐，无真实货币价值"；未满年龄提示 |
| 兼容 | Node ≥ 20；MCP 协议版本协商（客户端/服务端共同支持的最高版本） |
| 可观测 | 结构化日志 + 指标：`spin_latency`、`spin_error_rate`、`rtp_realized`、`feature_trigger_rate`、`active_sessions` |

---

## 4. CONFIG Schema（引擎与主题的唯一契约）

```jsonc
// packages/themes/fruit-classic-3x3/config.json
{
  "gameId": "fruit-classic-3x3",
  "configVersion": "1.0.0",
  "engineVersion": "^1.0.0",          // 引擎兼容区间，不匹配则拒绝加载
  "displayName": { "zh-CN": "经典水果机", "en-US": "Fruit Classic" },
  "rtp": { "target": 0.9610, "profile": "standard", "tolerance": 0.005 },
  "volatility": "low",
  "grid": { "reels": 3, "rows": 3 },
  "bet": { "lines": 5, "lineBetLevels": [1, 2, 5, 10, 20], "defaultLineBetIndex": 0, "maxTotalBet": 100 },
  "payEvaluator": { "type": "paylines", "lines": [[0,0,0],[1,1,1],[2,2,2],[0,1,2],[2,1,0]], "direction": "leftToRight" },
  "symbols": {
    "S7":    { "kind": "WILD",    "substitutesExcept": ["SCATTER"], "wildMultiplier": 1 },
    "BELL":  { "kind": "SCATTER", "minCount": 3, "paysAnywhere": true },
    "GRAPE": { "kind": "REGULAR" }, "WATERMELON": { "kind": "REGULAR" },
    "LEMON": { "kind": "REGULAR" }, "CHERRY": { "kind": "REGULAR" }
  },
  "reels": { "mode": "strips", "strips": [["GRAPE","LEMON", "..."], ["..."], ["..."]] },  // 或 mode: "weighted"
  "paytable": { "GRAPE": { "3": 20 }, "WATERMELON": { "3": 10 }, "LEMON": { "3": 5 }, "S7": { "3": 100 } },
  "features": [
    { "id": "free_spins", "trigger": { "symbol": "BELL", "minCount": 3 },
      "award": { "spins": 10, "multiplier": 2 }, "retrigger": { "minCount": 3, "addSpins": 5, "maxSpins": 50 } }
  ],
  "assets": { "symbols": { "GRAPE": "symbols/grape.png" }, "background": "bg/cabinet.jpg", "audio": { "spin": "sfx/spin.mp3" } },
  "uiHints": { "reelSpinMs": 900, "reelStopStaggerMs": 140, "theme": { "primary": "#e0483b", "accent": "#ffcc33" } }
}
```

- schema 用 **Zod** 定义并作为 `engine` 的公开类型来源（配置即类型）。
- `engineVersion` 做 semver 兼容校验，避免引擎升级后旧配置静默出错。

---

## 5. 文件结构

```
slot-collection/
├─ package.json                    # pnpm workspace 根
├─ pnpm-workspace.yaml
├─ tsconfig.base.json
├─ packages/
│  ├─ engine/                      # 与主题无关的核心（唯一"代码"层）
│  │  ├─ src/
│  │  │  ├─ rng.ts                 # HMAC-SHA256 确定性随机流
│  │  │  ├─ reel.ts                # strips / weighted 采样
│  │  │  ├─ evaluators/            # paylines.ts / ways.ts
│  │  │  ├─ features/              # freeSpins.ts / respin.ts / holdAndSpin.ts / pickBonus.ts
│  │  │  ├─ stateMachine.ts        # 一次 spin 的阶段编排
│  │  │  ├─ ledger.ts              # 整数账本
│  │  │  ├─ schema.ts              # Zod：ConfigSchema / SpinInput / SpinResult
│  │  │  ├─ validate.ts            # 配置校验 + 理论 RTP
│  │  │  ├─ simulate.ts            # 蒙特卡洛仿真
│  │  │  └─ index.ts               # createGame(gameId, overrides?) 统一入口
│  │  └─ tests/                    # 单测 + 黄金用例（golden/*.json）
│  ├─ themes/                      # 纯数据，禁止放逻辑
│  │  ├─ fruit-classic-3x3/{config.json, assets/}
│  │  ├─ book-of-pharaoh-5x3/{config.json, assets/}
│  │  └─ mega-ways-lite-6x4/{config.json, assets/}
│  ├─ registry/                    # gameId → config 的注册、合并 overrides、版本管理
│  ├─ mcp-server/                  # MCP 适配层
│  │  ├─ src/transports/{stdio.ts, http.ts}
│  │  ├─ src/tools/slot.ts         # tool 定义（inputSchema 由 Zod 生成）
│  │  ├─ src/sessionStore.ts       # 会话持久化（内存 LRU / 可选 Redis）
│  │  └─ src/health.ts
│  └─ web/                         # 前端机台
│     ├─ src/pages/{Lobby,Cabinet}.tsx
│     ├─ src/components/{ReelGrid,PaytableModal,WinLines,BetPanel,FreeSpinBar,BigWin,Toast}.tsx
│     ├─ src/mcp/client.ts         # MCP 客户端（transport 可切换）
│     └─ src/store.ts              # zustand
├─ config/{default.json, dev.json, prod.json}   # 环境级 overrides
├─ tests/e2e/                      # 跨三款主题的契约测试
└─ cloudbaserc.json                # 【可选】上云部署声明
```

---

## 6. 依赖说明

| 层 | 依赖 | 版本建议 | 说明 |
| --- | --- | --- | --- |
| 运行时 | Node.js | ≥ 20 LTS | TS 原生 ESM |
| 语言 | TypeScript | ^5.6 | strict 模式 |
| 校验 | zod | ^3.23 | 配置 schema + MCP tool inputSchema 单一来源 |
| MCP | `@modelcontextprotocol/sdk` | ^1.x | server / client / transport |
| HTTP transport | `express` 或 `hono` | ^4 / ^4 | Streamable HTTP + SSE |
| 会话持久化（可选） | `ioredis` 或 CloudBase SDK | — | 多实例部署时必选 |
| 测试 | `vitest` | ^2 | 单测 + 属性测试 |
| 仿真 | `worker_threads`（内置） | — | 百万次并行 |
| 前端 | React ^18 + Vite ^5 | — | 机台 UI |
| 前端动效 | `framer-motion` 或纯 CSS `@keyframes` | ^11 | 建议纯 CSS 保证低端设备流畅 |
| 前端状态 | `zustand` | ^4 | 轻量 |
| 可选部署 | `@cloudbase/cli` / `@cloudbase/js-sdk` | — | 【待确认】是否需要上云 |

> 引擎层 **零第三方运行时依赖**（仅 Node 内置 `crypto`），保证可移植与可审计。

---

## 7. 集成步骤（与 MCP 服务通信）

### 7.1 启动与协议
1. `pnpm i && pnpm -r build`
2. 本地 stdio：`node packages/mcp-server/dist/index.js --transport stdio`
3. 远程 HTTP：`--transport http --port 8787`，端点 `POST /mcp`，请求头 `Accept: application/json, text/event-stream`；响应头回传 `Mcp-Session-Id`，后续请求需携带。
4. 初始化握手：客户端发 `initialize`（声明 `protocolVersion` + `capabilities`），服务端回 `initializeResult`；客户端再发 `notifications/initialized`。**版本不被支持时服务端返回支持的最高版本，客户端应据此重试或直接报错**（不做静默降级）。
5. `tools/list` 暴露全部 `slot.*`；每个 tool 的 `inputSchema` 由 Zod 转 JSON Schema 生成，保证前后端同源。

### 7.2 调用时序（一次 spin）
```
create_session {gameId, denomination, clientSeed} -> sessionId
   └─ 服务端: 生成 serverSeed，落库，返回 {sessionId, credit, config(精简), betLevels}
spin {sessionId, lineBetIndex, lines?, requestId}
   ├─ 幂等: requestId 命中缓存 -> 直接返回上次结果
   ├─ 并发: 该 session 有 in-flight -> 40010 SPIN_IN_FLIGHT
   ├─ 校验: 下注档位 / 余额 / configVersion
   ├─ engine.spin(state, config, rng) -> {grid, wins, featureEvents, creditDelta}
   └─ 返回完整 SpinResult（含逐阶段事件，供前端分段播放动画）
get_state {sessionId}            // 断线重连恢复
end_session {sessionId}          // 结算 + 落审计
```

### 7.3 接入既有项目（若"现有老虎机项目"确实存在）
1. 以 `packages/engine` 作为**独立包**引入，不改动其现有目录结构；
2. 在现有服务上新增 `/mcp` 路由与 `slot.*` tool 注册，**与已有 tool 并列**，复用现有鉴权/限流中间件；
3. 现有游戏用一个"兼容 adapter"包成 theme config，纳入注册表，实现新旧共用同一入口；
4. 灰度：`config.audience` 命中才走新引擎，其余回落旧实现。

---

## 8. 运行稳定性

| 风险 | 措施 |
| --- | --- |
| 单次 spin 卡死/超时 | 引擎计算硬超时 200ms，超时中断并返回 `ENGINE_TIMEOUT`；绝不返回半成品结果 |
| 会话状态丢失 | 引擎无状态 + 会话持久化；`get_state` 可从最后一次已提交 `spinId` 重建；定期快照 |
| 重复扣款 | `requestId` 幂等 + 账本事务 + `verify_spin` 对账 |
| 配置出错导致赔付异常 | **启动时全量 `validate_config`**，任一主题不达标则整体启动失败（fail-fast）；灰度配置单独校验 |
| 流量突增 | 每 session 串行 + 全局 `active_spins` 限流 + token bucket；超限返回 `429`-语义错误码并带 `retryAfterMs` |
| 依赖（Redis/DB）抖动 | 降级到内存 LRU（单实例可用），并打告警；不允许静默丢账 |
| 客户端断线 | 前端 SSE/轮询重连 → `get_state` 恢复；动画状态机从 `phase` 续播 |
| 版本漂移 | `engineVersion` + `configVersion` 双校验；结果里回传版本号，前端版本不匹配时提示刷新 |
| 审计 | 每次 spin 写结构化日志（含 seed/nonce），保留 ≥30 天；提供 `verify_spin` 复核接口 |

---

## 9. 前端界面元素与响应逻辑

### 9.1 大厅页 `/`
- 机台卡片网格（封面、名称、RTP 标签、波动标签、"试玩"按钮）；顶部搜索 + 标签筛选（新/热门/高波动）；卡片点击 → `/cabinet/:gameId`。

### 9.2 机台页 `/cabinet/:gameId`
**布局**：上=机台标题/RTP/帮助按钮；中=转轮网格；下=控制条。

| 元素 | 行为 |
| --- | --- |
| 转轮网格 `ReelGrid` | 按 `grid.reels × grid.rows` 渲染（**尺寸由 config 决定**，组件不写死）；`uiHints.reelSpinMs` / `reelStopStaggerMs` 控制逐列停止；cascading 主题支持消除+下落动画 |
| 余额/总注/本次赢分 | 服务端权威，前端仅展示；赢分滚动累加动画 |
| 下注面板 `BetPanel` | 线注档位（来自 `bet.lineBetLevels`）、线数（固定线主题隐藏）、最大注、auto-spin（次数 + 余额跌破/单注大奖停止条件） |
| SPIN 按钮 | 请求中 `disabled` + 防连点（200ms 节流）；响应后按 `phase` 顺序播放 |
| 赢线展示 `WinLines` | 按 `wins[]` 逐条高亮符号 + 连线（SVG overlay），多条时轮播，全部展示完进入结算 |
| 免费旋转条 `FreeSpinBar` | 剩余次数、当前倍率、选中的 expanding symbol；retrigger 时 +N 动效 |
| BigWin 弹层 | 赢分 ≥ `bet × 10` 触发分级动画（Big / Mega / Epic），动画结束才允许下一次 spin |
| Paytable 弹层 | 由 `paytable` + `symbols` + `features` 自动渲染，无需手写文案 |
| 设置 | 音效开关、快速模式（缩短动画）、省电（降帧）、语言 |
| 提示条 | 首次进入展示"虚拟娱乐积分，无真实货币价值" |

**响应逻辑（关键）**
1. **服务端权威**：前端不计算任何赔付，只播放服务端返回的事件流。
2. **分段状态机**：`IDLE → REQUESTING → SPINNING → STOPPING → EVAL_WINLINES → FEATURE → SETTLE → IDLE`；每个阶段由 `SpinResult.events[].phase` 驱动，动画时长受 `uiHints` 与"快速模式"影响。
3. **乐观 + 回滚**：先扣款展示，若返回 `INSUFFICIENT_CREDIT` / 网络失败 → 回滚到上一 `credit` 并 toast；`SPIN_IN_FLIGHT` 视为忽略（不报错）。
4. **断线恢复**：任何阶段断线 → 重连后 `get_state`，若服务端已结算则直接跳到 `SETTLE` 播放结果；未结算则等服务端返回。
5. **错误分级**：配置/版本类错误 → 阻断页；业务类（余额不足）→ toast；网络类 → 自动重试 2 次（指数退避 300/900ms）后提示。
6. **无障碍/性能**：`prefers-reduced-motion` 关闭动画；转轮用 CSS transform + `will-change`；资源懒加载；首屏 < 2s。

---

## 10. 验收标准（Definition of Done）

1. 新增一款主题**仅需**新增 `config.json` + 资源 + 一条注册表记录，`packages/engine` 代码 diff 为 0。
2. 三款主题共用同一 `ReelGrid`/`Paytable`/`WinLines` 组件，切换只换 config。
3. `simulate` 100 万次：实测 RTP 与目标偏差 ≤ 0.5%，特性触发频率落在设计区间。
4. `verify_spin` 对任意历史 `spinId` 复算结果一致。
5. 单 spin 引擎 P95 < 50ms；`tools/list` 中所有 tool 有契约测试（含错误码路径）。
6. 同一 session 并发 spin → `SPIN_IN_FLIGHT`，且不产生重复扣款。
7. 进程被 kill 后重启，会话可通过 `get_state` 恢复（持久化模式下）。
8. MCP 协议握手、版本协商、`tools/list`、`tools/call` 全部通过官方 inspector 校验。

---

## 11. 里程碑

| 阶段 | 交付 |
| --- | --- |
| **M1** | 脚手架（pnpm workspace + TS + vitest）；engine 核心（RNG/卷轴/paylines/账本/schema/validate）；`fruit-classic-3x3` 配置 + 仿真达标；单测 |
| **M2** | MCP Server（stdio + HTTP）+ sessionStore + 全部 `slot.*` tool；契约测试；`book-of-pharaoh-5x3`（验证 free spins + expanding，引擎零改动） |
| **M3** | 前端大厅 + 机台页完整交互；`mega-ways-lite-6x4`（验证 ways + cascading，引擎零改动） |
| **M4** | 稳定性加固：限流/熔断/审计/指标/断线恢复；性能达标 |
| **M5** | 【可选】CloudBase 部署（静态托管 + 云函数/云托管）+ 域名与监控 |

---

## 12. 开放问题（【待确认】）

1. **现有项目基线在哪？** 当前工作区为空。请提供仓库路径，或确认按本文从零落地。
2. **"Blender MCP" 具体指什么？** 是自建 MCP Server、CloudBase 云函数形态，还是某个第三方 MCP？这决定 §7 的 transport 与部署方式。
3. **是否需要服务端账本持久化（用户余额跨会话）？** 若需要，选 Redis 还是 CloudBase 数据库/PG。
4. **是否需要上云部署？** 若需要，走 CloudBase 静态托管 + 云函数，还是云托管（长连接更适合 SSE）。
5. **主题优先级**：先做经典 3×3（快）还是直接冲 Book 系（更能验证引擎表达力）？
6. **积分 vs 真钱**：本文按纯娱乐积分设计；若涉及真钱需另行评估合规与牌照。

---

## 13. 与原始需求的差异说明（补全了什么）

| 原始表述 | 补全后 |
| --- | --- |
| "至少新增一款热门游戏" | 明确 3 款（含布局/机制/RTP/波动），并规定 M1 下限与"加游戏不改引擎"的验收方式 |
| "定义核心机制" | 拆解为 RNG、卷轴采样、赔付求值、符号能力矩阵、特性状态机、账本六个可测子模块 |
| "统一入口调用" | 定义为 `createGame(gameId, overrides)` + MCP `slot.*` 工具集 + 统一响应/错误码 |
| "支持参数配置" | CONFIG Schema（Zod）+ 环境级 overrides + 版本兼容校验 + 启动时强制校验 |
| "文件结构/依赖/集成步骤" | 给出 monorepo 目录树、依赖表、stdio/HTTP 两种 transport 的时序与握手细节 |
| "保证运行稳定性" | 超时/幂等/限流/熔断/持久化/断线恢复/审计/指标的逐条措施 |
| "前端展示或交互" | 大厅与机台页的元素清单、状态机、动画与错误处理逻辑 |
| （缺失） | 补充：现状核查与假设、硬约束与非功能指标、验收标准、里程碑、开放问题 |
