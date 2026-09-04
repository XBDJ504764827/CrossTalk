/*
	CrossTalk - Chat
	核心逻辑：旁路监听玩家聊天（不阻断 gokz-chat 等），决策是否跨服转发并写库；
	接收端渲染：跨服聊天 [服务器名]玩家名:消息 与 喊话聊天框同步显示。

	关键机制（已从 SourceMod 源码确认）：
	  - OnClientSayCommand 是 ET_Event 类型 forward：即使 gokz-chat 返回 Plugin_Handled，
	    本插件的回调依然会被执行（循环不提前 break）。
	  - 本插件只旁路监听、返回 Plugin_Continue（不阻断），完全不干扰 gokz-chat 的本地显示。
	  - '!'/'/' 开头的消息不写库（命令语义，天然排除 !cr / !crall 等）。
*/

// =====[ PUBLIC ]=====

void CT_Chat_Init()
{
	// 无初始化（事件钩子由 SourceMod 自动转发到 OnClientSayCommand）
}

// 玩家说了一句话（事件由入口转发）
void CT_OnClientSay(int client, const char[] command, const char[] message)
{
	if (!CT_IsEnabled())
	{
		return;
	}
	if (client <= 0 || client > MaxClients)
	{
		return; // 服务器/控制台消息不转发
	}
	if (!IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	// 只转发公共聊天（say_team 不转发，但保留未来扩展 ConVar）
	if (!StrEqual(command, "say", false))
	{
		return;
	}

	// 玩家私有显示消息（不转发）
	if (StrEqual(message, "PLAYER_DISCONNECTED", false) || StrEqual(message, "PLAYER_CONNECTED", false))
	{
		return;
	}

	// 命令不转发
	if (CT_IsCommand(message))
	{
		return;
	}

	// 净化消息
	char sanitized[CT_MAX_MSG_LENGTH + 1];
	CT_SanitizeMessage(message, sanitized, sizeof(sanitized));
	if (CT_IsEmpty(sanitized))
	{
		return;
	}

	// !cr 关闭跨服发送 → 只留在本服（不写库）
	if (!CT_PlayerCrEnabled(client))
	{
		return;
	}

	// 获取玩家信息
	char playerName[MAX_NAME_LENGTH];
	GetClientName(client, playerName, sizeof(playerName));

	char steamId[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
	{
		Format(steamId, sizeof(steamId), "0");
	}

	CT_LogDebug("Forward message from %s (steam=%s): %s", playerName, steamId, sanitized);

	// 写库（异步，不阻塞主线程）
	CT_DB_InsertMessage(gC_ServerId, gC_ServerName, playerName, steamId, CT_MSG_TYPE_CHAT, sanitized);
}

// =====[ RENDER (RECEIVE) ]=====

// 接收端显示跨服聊天
void CT_Chat_ShowCrossChat(const char[] serverName,
						   const char[] playerName, const char[] content)
{
	char prefix[192];
	char color[16];
	if (gCV_ChatColor != null)
	{
		gCV_ChatColor.GetString(color, sizeof(color));
	}
	else
	{
		strcopy(color, sizeof(color), "{default}");
	}

	char colorCode[32];
	CT_ApplyColor(color, colorCode, sizeof(colorCode));

	Format(prefix, sizeof(prefix), "[%s]%s:%s", serverName, playerName, content);

	// PrintToChatAll 自动添加聊天框首字符
	PrintToChatAll("%s[%s]%s: %s", colorCode, serverName, playerName, content);
}

// 接收端显示喊话（聊天框部分）
void CT_Chat_ShowAnnounce(const char[] serverName,
						  const char[] playerName, const char[] content)
{
	char color[16];
	if (gCV_AnnounceColor != null)
	{
		gCV_AnnounceColor.GetString(color, sizeof(color));
	}
	else
	{
		strcopy(color, sizeof(color), "{red}");
	}

	char colorCode[32];
	CT_ApplyColor(color, colorCode, sizeof(colorCode));

	PrintToChatAll("%s[CrossTalk][%s]%s: %s", colorCode, serverName, playerName, content);
}
