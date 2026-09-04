/*
	CrossTalk - State
	定时器：轮询共享 DB 新消息、定时清理过期消息；
	玩家 !cr 开关状态（Cookie 持久化，跨服务器生效）；
	渲染分派：新消息按类型分发给 chat.sp / hud.sp。
*/

// =====[ STATE ]=====

bool gB_CrEnabledCache[MAXPLAYERS + 1]; // 玩家 !cr 发送开关缓存（默认开）
bool gB_CookiesCached[MAXPLAYERS + 1];

// =====[ PUBLIC ]=====

void CT_State_Init()
{
	// 轮询定时器
	float interval = gCV_PollInterval != null ? gCV_PollInterval.FloatValue : 0.5;
	CreateTimer(interval, CT_Timer_Poll, _, TIMER_REPEAT);
	if (CT_IsDebug())
	{
		LogMessage("[CrossTalk] Poll timer started: %.2fs", interval);
	}

	// 清理定时器
	float cleanup = gCV_CleanupInterval != null ? gCV_CleanupInterval.FloatValue : 300.0;
	CreateTimer(cleanup, CT_Timer_Cleanup, _, TIMER_REPEAT);
}

void CT_State_OnClientConnected(int client)
{
	gB_CrEnabledCache[client] = true;
}

void CT_State_OnClientCookiesCached(int client)
{
	if (!CT_IsValidClient(client))
	{
		return;
	}
	char value[4];
	GetClientCookie(client, gH_CrossTalkCookie, value, sizeof(value));
	if (value[0] == '\0')
	{
		// 首次连接：默认开启
		gB_CrEnabledCache[client] = true;
	}
	else
	{
		gB_CrEnabledCache[client] = value[0] == '1';
	}
	gB_CookiesCached[client] = true;
}

// 玩家是否开启跨服发送（默认开）
bool CT_PlayerCrEnabled(int client)
{
	if (client < 1 || client > MaxClients)
	{
		return true;
	}
	return gB_CrEnabledCache[client];
}

// 切换 !cr 状态（Cookie 持久化）
void CT_SetPlayerCrEnabled(int client, bool enabled)
{
	gB_CrEnabledCache[client] = enabled;
	char value[2];
	Format(value, sizeof(value), "%d", enabled ? 1 : 0);
	SetClientCookie(client, gH_CrossTalkCookie, value);
}

// =====[ TIMERS ]=====

public Action CT_Timer_Poll(Handle timer)
{
	if (!CT_IsEnabled() || gH_DB == null || !gB_DBReady)
	{
		return Plugin_Continue;
	}

	CT_DB_PollNewMessages();
	return Plugin_Continue;
}

public Action CT_Timer_Cleanup(Handle timer)
{
	if (!CT_IsEnabled() || gH_DB == null || !gB_DBReady)
	{
		return Plugin_Continue;
	}
	CT_DB_Cleanup();
	return Plugin_Continue;
}

// =====[ RENDER DISPATCH ]=====

// 渲染一条收到的共享消息（来自轮询）
void CT_RenderIncomingMessage(const char[] serverId, const char[] serverName,
							  const char[] playerName, int msgType, const char[] content)
{
	// 本服自己的消息（本地已显示）→ 跳过渲染
	// 判定：server_id == 本服 server_id
	// 本地插入的消息轮询回来时 server_id==本服 → 跳过；
	// 喊话 !crall 由本服管理员发起，本地已由命令回显（HUD+聊天），同样跳过。
	if (StrEqual(serverId, gC_ServerId, false))
	{
		return;
	}

	switch (msgType)
	{
		case CT_MSG_TYPE_ANNOUNCE:
		{
			// 管理员喊话：HUD 弹屏 + 聊天框
			CT_HUD_ShowAnnounce(serverName, playerName, content);
			CT_Chat_ShowAnnounce(serverName, playerName, content);
		}
		default:
		{
			// 玩家跨服聊天（未知类型也按聊天显示）
			CT_Chat_ShowCrossChat(serverName, playerName, content);
		}
	}
}
