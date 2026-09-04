/*
	CrossTalk
	---------------------------------------------
	CS:GO 跨服聊天插件：同一物理机上的多个游戏服务器共享消息总线（一个 SQLite
	文件），玩家在某服聊天栏发送的消息会实时出现在所有服务器的聊天栏。

	【架构】
	  - 消息总线 = 共享 SQLite 文件（SourceMod 自带 dbi/sqlite 扩展，零第三方依赖）
	    * 默认路径: <SM>/data/crosstalk/shared.sq3
	      （所有服务器共享同一 <SM>/data/ 目录时，默认零配置即可互通）
	    * 也可用 ConVar cross_talk_db_path 显式指定，如
	      file:/home/steam/shared/crosstalk.sq3
	  - 消息流转:
	      玩家 say → OnClientSayCommand 旁路监听（不打断 gokz-chat 等）→ INSERT 写库
	        → 每个服务器每 cross_talk_poll_interval 秒轮询 id > last_read 的新消息
	        → 渲染到本服聊天栏（[hostname]玩家名:消息）

	【功能】
	    !cr      每个玩家独立开关"发送"跨服聊天（Cookie 持久化）
	             关闭后：自己发的消息只留在本服；仍可接收其他服的跨服聊天
	             管理喊话（!crall）永远可见，不可被屏蔽
	    !crall   管理员（默认 ADMFLAG_CHAT）跨服喊话：
	             所有服务器 HUD 弹屏（SetHudTextParams + ShowSyncHudText）
	             + 聊天框同步醒目显示

	【与 GOKZ 兼容】
	  - 不依赖 GOKZ 任何 include/插件；gokz-chat 返回 Plugin_Handled 时
	    CrossTalk 仍能收到 OnClientSayCommand（事件转发独立），只旁路监听、
	    不返回 Handled，完全不干扰 gokz-chat 的本地显示。
	  - 一切以 '!' 或 '/' 开头的消息不写库（命令语义）。

	【依赖】
	  SourceMod 1.11+（自带 dbi + sqlite 扩展，CS:GO 原版即携带）
*/

#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#include <dbi>

#include <crosstalk/version>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
	name = "CrossTalk",
	author = "XBDJ504764827",
	description = "Cross-server chat relay & admin global announcement (shared SQLite bus)",
	version = CROSSTALK_VERSION,
	url = "https://github.com/XBDJ504764827/CrossTalk"
};

#include "crosstalk/convars.sp"
#include "crosstalk/helpers.sp"
#include "crosstalk/db.sp"
#include "crosstalk/state.sp"
#include "crosstalk/chat.sp"
#include "crosstalk/hud.sp"
#include "crosstalk/commands.sp"

// =====[ PLUGIN EVENTS ]=====

public void OnPluginStart()
{
	CT_CreateConVars();
	CT_InitHelpers();
	CT_DB_Init();
	CT_State_Init();
	CT_Chat_Init();
	CT_HUD_Init();
	CT_Commands_Init();
}

public void OnMapStart()
{
}

public void OnConfigsExecuted()
{
	CT_RefreshServerName();
	// hostname 在 config 阶段才最终确定：刷新 server_id 并重载 last_read
	CT_DB_RefreshServerIdentity();
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	CT_OnClientSay(client, command, sArgs);
	// 只旁路监听，不阻断其他插件（gokz-chat 等可继续处理）
	return Plugin_Continue;
}

public void OnClientConnected(int client)
{
	CT_State_OnClientConnected(client);
}

public void OnClientDisconnect(int client)
{
	// 玩家离开时无需特殊处理（Cookie 持久化）
}

public void OnClientCookiesCached(int client)
{
	CT_State_OnClientCookiesCached(client);
}
