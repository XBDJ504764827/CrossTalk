# CrossTalk

CS:GO 跨服聊天插件：同一物理机上的多个游戏服务器共享消息总线（一个 SQLite 文件），玩家在某服聊天栏发送的消息会实时出现在所有服务器的聊天栏；管理员可发起跨服喊话，在所有服务器 HUD 弹屏 + 聊天框同步显示。

## 特性

- 🌐 **跨服聊天**：玩家 `say` 的消息默认跨服显示（`[服务器名]玩家名:消息`），服务器名取本服 `hostname`
- 💬 **个人开关 `!cr`**：每个玩家独立开关"发送"跨服聊天（Cookie 持久化，跨服务器生效）
  - 关闭后：自己发的消息只留在本服；**仍可接收**其他服的跨服聊天；管理员喊话**永远可见**、不可被屏蔽
- 📢 **管理员喊话 `!crall`**：默认 `ADMFLAG_CHAT`（ConVar 可改），所有服务器 **HUD 弹屏**（参考 Hud-Text-Message 的 `SetHudTextParams` 参数体系，全部 ConVar 化）+ **聊天框同步显示**
- 💾 **SQLite 共享总线**：SourceMod 自带 `dbi` + `sqlite` 扩展，零第三方依赖；同一物理机共享 `data/` 目录时**默认零配置**
- 🧱 **单一 SMX**：`crosstalk.sp` + 模块目录，仅产出一个 `crosstalk.smx`
- ⚙️ **CI 自动化**：PR 编译检查 + 测试包 artifact；合并 main 自动打 tag 发 Release

## 架构

```
[服 A 玩家 say "hello"]
      │
      ▼ 旁路监听 OnClientSayCommand（不打断 gokz-chat 等）
 crosstalk.smx（服 A）
      │ INSERT
      ▼
 ┌──────────────────────────────────────┐
 │ 共享 SQLite（所有服务器同一文件）     │
 │ addons/sourcemod/data/crosstalk/      │
 │   shared.sq3                          │
 │   messages + server_state 表          │
 └──────────────────────────────────────┘
      ▲
      │ 每 0.5s 轮询 id > last_read
 crosstalk.smx（服 B ... 服 N）
      │ 渲染 [服务器名]玩家名:消息
      ▼
 [服 B 玩家看到]
```

- 消息延迟 ≤ 轮询间隔（默认 0.5s，ConVar `cross_talk_poll_interval`）
- 零第三方依赖：无需 GOKZ、SteamWorks、sourcemod-colors（内置轻量色码）

## 编译

```sh
./build.sh setup   # 首次：下载 SourceMod 1.11 编译器到 .sm111/
./build.sh         # 编译 → addons/sourcemod/plugins/crosstalk.smx
STRICT=1 ./build.sh  # 警告即错误（CI 用）
```

## 安装

1. 下载 `Releases` 中 `crosstalk-vX.Y.Z.zip`（或 PR 测试包 `crosstalk-TEST-PR{N}.zip`）。
2. 将 `addons/`、`cfg/` 合并进 CS:GO 服务器根目录。
3. 首次启动自动生成 `cfg/sourcemod/crosstalk.cfg`；所有服务器需配置**同一个共享 DB 路径**（默认共享 `data/` 目录时零配置）。
4. 重启服务器或 `sm plugins load crosstalk`。

## 命令

| 命令 | 权限 | 说明 |
|------|------|------|
| `!cr` | 全部玩家 | 开关个人"发送"跨服聊天（关闭不禁接收，喊话不可屏蔽） |
| `!crall <消息>` | 管理员（默认 `ADMFLAG_CHAT`） | 跨服喊话：所有服务器 HUD 弹屏 + 聊天框显示 |

## ConVars

| ConVar | 默认 | 说明 |
|--------|------|------|
| `cross_talk_enabled` | 1 | 总开关 |
| `cross_talk_db_path` | `file:addons/sourcemod/data/crosstalk/shared.sq3` | 共享 SQLite 路径（所有服必须同一文件） |
| `cross_talk_server_id` | (hostname) | 服务器标识（消息来源/去重） |
| `cross_talk_poll_interval` | 0.5 | 轮询间隔（秒） |
| `cross_talk_announce_flag` | b | 喊话权限位 |
| `cross_talk_chat_color` | `{default}` | 跨服聊天颜色 |
| `cross_talk_announce_color` | `{red}` | 喊话聊天框颜色 |
| `cross_talk_hud_x / y` | -1.0 / 0.1 | HUD 弹屏位置 |
| `cross_talk_hud_holdtime` | 5.0 | HUD 显示时长（秒） |
| `cross_talk_hud_r / g / b` | 255 / 80 / 80 | HUD 颜色 |
| `cross_talk_hud_alpha` | 255 | HUD 透明度 |
| `cross_talk_hud_effect` | 1 | HUD 效果（0 淡入 1 闪烁 2 淡出） |
| `cross_talk_hud_fadein / fadeout` | 0.5 / 0.5 | 淡入淡出时长 |
| `cross_talk_message_ttl_days` | 7 | 消息保留天数 |
| `cross_talk_cleanup_interval` | 300 | 清理间隔（秒） |
| `cross_talk_debug` | 0 | 调试日志 |

## 目录结构

```
addons/sourcemod/scripting/crosstalk.sp        # 唯一入口
addons/sourcemod/scripting/crosstalk/           # 模块目录（单 SMX）
addons/sourcemod/scripting/include/crosstalk/version.inc  # 版本号（PR 前手动 bump）
addons/sourcemod/translations/                 # crosstalk.phrases.txt
cfg/sourcemod/crosstalk.cfg                    # 配置模板（运行时自动生成）
docs/DEVELOPMENT.md                            # 开发文档
build.sh                                       # 编译脚本
.github/workflows/pr-check.yml                 # PR：编译检查 + 测试包
.github/workflows/release.yml                  # push main：tag + Release
```

## 依赖

- SourceMod 1.11+（自带 `dbi` + `sqlite` 扩展，CS:GO 原版即携带）
- 无 GOKZ / SteamWorks / sourcemod-colors 等第三方依赖
- 兼容 GOKZ 环境：`gokz-chat` 实现 `OnClientSayCommand` 返回 `Plugin_Handled`，CrossTalk 旁路监听、不阻断，互不干扰

## 许可证

由 XBDJ504764827 开发，遵循 GPL-3.0 或等价开源协议。
