# CrossTalk 开发文档

> CS:GO 跨服聊天插件 —— 同一物理机多游戏服务器共享消息总线（SQLite 单文件），玩家聊天跨服可见，管理员可跨服喊话（HUD 弹屏 + 聊天框）。

- 插件名：`crosstalk`
- 最终产物：**一个** `crosstalk.smx`
- 代码结构：模仿 `gokz-top-plugins` / `guideline`（单入口 `.sp` + 同名模块目录 + `include/` 依赖）
- 通信架构：参考 replay-vault 的"共享存储"思路，但**零第三方依赖**（只用 SourceMod 自带 dbi/sqlite）

---

## 1. 项目概述

### 1.1 解决什么问题

同一物理机上运行多个 CS:GO 服务器，各进程独立，玩家聊天无法互见。CrossTalk 用一个**共享 SQLite 文件**作为消息总线，玩家在某服的 `say` 消息实时出现在所有服务器聊天栏。

### 1.2 通信模型

| 组件 | 说明 |
|---|---|
| 消息总线 | 共享 SQLite（默认 `data/crosstalk/shared.sq3`，`file:` URI 绝对路径） |
| 写入端 | 每服 `OnClientSayCommand` 旁路监听 → INSERT |
| 读取端 | 每服定时器轮询 `SELECT id > last_read`（默认 0.5s） |
| 去重 | `server_id == 本服` 的消息跳过渲染（本地已显示） |

### 1.3 功能清单

| 功能 | 说明 |
|---|---|
| 跨服聊天 | `say`（公共聊天）默认跨服显示；`say_team` 不转发（后续 ConVar 扩展） |
| `!cr` | 玩家开关"发送"跨服聊天（Cookie 持久化），关→禁发不禁收 |
| `!crall` | 管理员喊话：所有服 HUD 弹屏 + 聊天框同步显示，不可被 `!cr` 屏蔽 |
| 消息清理 | TTL 7 天，每 300s 清理一次 |

### 1.4 核心约束

| 约束 | 说明 |
|---|---|
| 单一 SMX | 所有模块编译进一个 `crosstalk.smx` |
| 依赖最少 | 仅 SourceMod 1.11 自带 dbi + sqlite 扩展 |
| 不阻断聊天 | `OnClientSayCommand` 只旁路监听，永远 `Plugin_Continue`（gokz-chat 等不受影响） |
| 异步写库 | 所有 SQL 用 `SQL_TQuery` 异步，不阻塞主线程 |
| 命令不转发 | 以 `!`/`/` 开头的消息一律不写库 |

---

## 2. 目录结构

```
CrossTalk/
├── README.md
├── docs/DEVELOPMENT.md              # 本文档
├── addons/sourcemod/
│   ├── scripting/
│   │   ├── crosstalk.sp             # 唯一入口：myinfo / 事件集中转发 / include 全部模块
│   │   ├── crosstalk/               # 模块目录
│   │   │   ├── convars.sp           # ConVar 创建 + Cookie + 服务器名/ID
│   │   │   ├── helpers.sp           # 客户端校验 + 消息净化 + 色码 + 权限
│   │   │   ├── db.sp                # SQLite 连接/建表/写/轮询/清理
│   │   │   ├── state.sp             # 定时器（轮询/清理）+ 渲染分派 + !cr 状态
│   │   │   ├── chat.sp              # OnClientSayCommand 旁路监听 + 转发决策 + 接收端聊天渲染
│   │   │   ├── hud.sp               # HUD 弹屏（SetHudTextParams + ShowSyncHudText）
│   │   │   └── commands.sp          # !cr / !crall 命令
│   │   └── include/crosstalk/version.inc  # 版本号（PR 前手动 bump）
│   └── translations/                # crosstalk.phrases.txt
├── cfg/sourcemod/crosstalk.cfg      # 配置模板（运行时 autoexec 生成）
├── build.sh                         # 本地编译脚本
└── .github/workflows/
    ├── pr-check.yml                 # PR：编译（STRICT）+ 测试包 artifact
    └── release.yml                  # push main：tag + Release
```

### 2.1 模块加载方式

```pawn
#include "crosstalk/convars.sp"
#include "crosstalk/helpers.sp"
#include "crosstalk/db.sp"
#include "crosstalk/state.sp"
#include "crosstalk/chat.sp"
#include "crosstalk/hud.sp"
#include "crosstalk/commands.sp"
```

入口 `crosstalk.sp` 只负责集中接收 SourceMod 事件并转发给各模块：

- `OnPluginStart` → `CT_CreateConVars / CT_InitHelpers / CT_DB_Init / CT_State_Init / CT_Chat_Init / CT_HUD_Init / CT_Commands_Init`
- `OnConfigsExecuted` → `CT_RefreshServerName`（hostname 动态刷新）
- `OnClientSayCommand` → `CT_OnClientSay`（旁路监听）
- `OnClientConnected` / `OnClientCookiesCached` → `CT_State_*`（!cr 状态）

---

## 3. 数据流

```
玩家服 A say "hello"
  └─ OnClientSayCommand（ET_Event：gokz-chat 等返回 Handled 也不影响我们收到）
       └─ 过滤：!cr 关闭？say_team？'!'/'/' 开头命令？→ 丢弃
       └─ CT_SanitizeMessage（剥离颜色码/换行/限长）
       └─ CT_DB_InsertMessage（异步 INSERT，msg_type=0）

每个服（含 A）定时轮询：
  └─ CT_DB_PollNewMessages → SELECT id > last_read ORDER BY id ASC
       └─ CT_RenderIncomingMessage（state.sp 分派）
            ├─ server_id == 本服 → 跳过（本地已显示）
            ├─ msg_type=0 → CT_Chat_ShowCrossChat（[服务器名]玩家:消息）
            └─ msg_type=1 → CT_HUD_ShowAnnounce + CT_Chat_ShowAnnounce
```

管理员 `!crall hello`：
```
  └─ CommandCrAll → 权限检查 → INSERT（msg_type=1）
       └─ 本服立即本地显示（CT_HUD_ShowAnnounce + CT_Chat_ShowAnnounce）
       └─ 远端服通过轮询显示（同 msg_type=1 路径，server_id != 本服）
```

---

## 4. SQLite 共享关键技术

### 4.1 路径解析

SourceMod sqlite 驱动（`SqDriver::Connect`）对 `file:` 开头的 database 名**直接透传**（不拼 `data/sqlite/`），支持绝对 URI。但**相对 `file:` URI 按进程 CWD 解析（不可控，会失败）**，因此插件统一解析为**绝对路径**：

```pawn
// 默认（零配置）：BuildPath(Path_SM, "data/crosstalk/shared.sq3") → file:<绝对路径>
// ConVar 覆盖：cross_talk_db_path "file:/home/steam/shared/crosstalk.sq3"
//   - 空             → <SM>/data/crosstalk/shared.sq3（同机器共享 data/ 即互通）
//   - file:/绝对路径  → 直接使用
//   - file:相对/普通相对 → 相对 <SM> 根解析
```

**目录自动创建**：SQLite 只自动创建数据库文件，**不创建目录**。`CT_EnsureDirectory` 在连接前逐级创建 `data/crosstalk/`；数据库文件不存在 → SQLite 自动创建；已存在 → 保留不覆盖。

### 4.2 并发安全（保持不变）

sqlite 驱动内置 `busy_handler`（100ms 重试等待），多进程并发写安全；消息吞吐低（每服 0.5s 一次 SELECT + 写入），远低于 SQLite 极限。无长事务。

### 4.3 表结构

```sql
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  server_id TEXT NOT NULL,      -- 来源服标识（hostname 或 cross_talk_server_id）
  server_name TEXT NOT NULL,    -- 来源服务器名（显示用）
  player_name TEXT NOT NULL,    -- 玩家昵称
  steam_id TEXT NOT NULL,       -- SteamID64（喊话为 "0"）
  msg_type INTEGER NOT NULL DEFAULT 0,  -- 0=聊天 1=喊话
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS server_state (
  server_id TEXT PRIMARY KEY,
  last_message_id INTEGER NOT NULL DEFAULT 0
);
```

---

## 5. 与 GOKZ 的兼容

- `gokz-chat.smx` 实现 `OnClientSayCommand` 返回 `Plugin_Handled` 后自行格式化打印（含 `GOKZ_CH_SetChatTag` 标签）。
- 已从 SourceMod 源码确认：`OnClientSayCommand` 是 **ET_Event** 类型 forward，**整条链路上每个插件都会收到回调**（即使前面的插件返回 `Plugin_Handled`，也不中断后续插件执行；最终聚合结果取最高值）。
- CrossTalk 只旁路监听、永远返回 `Plugin_Continue`，完全不干扰 gokz-chat。

---

## 6. 安全与健壮性

| 项目 | 措施 |
|---|---|
| SQL 注入 | `SQL_EscapeString` 转义所有字符串 |
| 消息净化 | `CT_SanitizeMessage` 剥离 `\x01-\x07` 颜色码、强制限长 256 |
| 命令泄漏 | `!`/`/` 开头不转发 |
| 重复显示 | `server_id == 本服` 跳过渲染 |
| DB 故障 | 连接失败仅 LogError，不崩溃；轮询防重入（`gB_Polling`） |
| 消息膨胀 | TTL 清理（默认 7 天） |

---

## 7. 关键 ConVar

| ConVar | 默认 | 说明 |
|---|---|---|
| cross_talk_enabled | 1 | 总开关 |
| cross_talk_db_path | `file:addons/sourcemod/data/crosstalk/shared.sq3` | 共享 DB 路径 |
| cross_talk_server_id | (空=hostname) | 服务器标识 |
| cross_talk_poll_interval | 0.5 | 轮询间隔 |
| cross_talk_announce_flag | b | 喊话权限 |
| cross_talk_chat_color | {default} | 聊天颜色 |
| cross_talk_announce_color | {red} | 喊话颜色 |
| cross_talk_hud_* | — | HUD 参数全套 |
| cross_talk_message_ttl_days | 7 | 消息 TTL |
| cross_talk_debug | 0 | 调试 |

---

## 8. CI 自动化

- **pr-check.yml**：PR → main 时编译（STRICT 警告即错误）+ 上传测试包 artifact（`crosstalk-TEST-PR{N}-v{V}-{sha}.zip`）
- **release.yml**：push main 时校验版本号 tag 未存在 → 编译 → 打包 `crosstalk-vX.Y.Z.zip` → 打 tag → GitHub Release
- 版本号维护在 `include/crosstalk/version.inc` 的 `CROSSTALK_VERSION`，开发者在每个 PR 前手动 bump（semver）

---

## 9. 测试要点

1. **双服互通**：两个不同 hostname 的服装插件，默认配置（共享 `data/`），A 服玩家 say → B 服聊天栏出现 `[A服名]玩家:消息`（≤0.5s）
2. **!cr 关闭**：A 服玩家 `!cr` 关闭后 say → 只有 A 服自己能看到；B 服玩家发消息 → A 服该玩家仍能看到
3. **!crall**：管理员在 A 服 `!crall 测试` → B 服 HUD 弹屏 + 聊天框红色显示；无权限玩家使用被拒
4. **GOKZ 兼容**：GOKZ 服上 gokz-chat 正常格式化本地聊天，CrossTalk 跨服消息正常
5. **重启恢复**：服务器重启后从 DB 续读 `last_read`，不丢消息、不重复显示
6. **命令隔离**：输入 `!cr` / `!abc` 等命令不跨服显示
