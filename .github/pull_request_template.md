# PR: develop → main

> 仅允许 `develop → main`。合并前 `pr-check` 必须通过（`STRICT=1` 零警告 + 单一 `smx` 校验），`Artifacts` 中 `crosstalk-TEST-PR{N}.zip` 为测试包。

## 变更类型

- [ ] 功能（`minor`）
- [ ] 修复（`patch`）
- [ ] 不兼容（`major`）

## 版本

- [ ] 已在 `addons/sourcemod/scripting/include/crosstalk/version.inc` 按 `semver` 自增（`Release` 以此打 `tag`，未自增会导致 `release.yml` 失败）
- 当前 `CROSSTALK_VERSION`: `x.y.z` → `x.y.z`

## Code Review 清单

- [ ] 无阻塞主线程的同步 I/O（仅允许异步 `SQL_TQuery`）
- [ ] `OnClientSayCommand` 永远返回 `Plugin_Continue`（不干扰 gokz-chat / basecomm 等）
- [ ] `!`/`/` 开头消息不写库（命令语义）
- [ ] `!crall` 喊话不可被玩家 `!cr` 屏蔽
- [ ] 聊天显示格式 `[服务器名]玩家名:消息`，服务器名实时取 `hostname`
- [ ] `say_team` 不转发（除非显式 ConVar 开启）
- [ ] 字符串全部 `SQL_EscapeString` 转义；消息经 `CT_SanitizeMessage` 净化
- [ ] `STRICT=1 ./build.sh` 零警告，产物仅 `1` 个 `crosstalk.smx`

## 测试

- [ ] 已下载 `Artifacts` 测试包在测试服验证
- [ ] 两台不同 hostname 服互通：A 服 say → B 服 `[A服名]玩家:消息`
- [ ] `!cr` 关闭后：本地可见 but 远端不可见；另一端消息仍能接收
- [ ] `!crall`：HUD 弹屏 + 聊天框显示；无权限玩家被拒
- [ ] GOKZ 服兼容：gokz-chat 正常格式化，跨服消息正常
- [ ] 删除 `cfg/sourcemod/crosstalk.cfg` 重启后重建；已有配置不丢失

## 备注

<!-- 重大改动说明、回滚要点等 -->
