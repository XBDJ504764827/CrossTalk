/*
	CrossTalk - Commands
	!cr      每个玩家独立开关"发送"跨服聊天（Cookie 持久化）
	         关闭后：自己发的消息只留在本服；仍可接收其他服的跨服聊天；
	         !crall 喊话永远可见，不可被屏蔽。
	!crall   管理员（默认 ADMFLAG_CHAT，cross_talk_announce_flag 可改）跨服喊话：
	         写库 → 所有服务器 HUD 弹屏 + 聊天框同步显示。

	命令注册为 sm_cr / sm_crall，玩家输入 !cr / !crall 经由 SourceMod chat trigger
	自动路由（不进入聊天转发管道；且命令消息以 '!' 开头也不会被转发）。
*/

// =====[ PUBLIC ]=====

void CT_Commands_Init()
{
	RegConsoleCmd("sm_cr", CommandCr, "CrossTalk: toggle cross-server chat sending.");
	RegConsoleCmd("sm_crall", CommandCrAll, "CrossTalk: admin cross-server announce <message>.");
}

// =====[ COMMAND HANDLERS ]=====

public Action CommandCr(int client, int args)
{
	if (!CT_IsValidClient(client))
	{
		ReplyToCommand(client, "[CrossTalk] This command can only be used in-game.");
		return Plugin_Handled;
	}

	bool enabled = !CT_PlayerCrEnabled(client);
	CT_SetPlayerCrEnabled(client, enabled);

	if (enabled)
	{
		PrintToChat(client, "\x01[\x04CrossTalk\x01] \x03跨服聊天已开启: 你的消息将显示在所有服务器。");
	}
	else
	{
		PrintToChat(client, "\x01[\x04CrossTalk\x01] \x03跨服聊天已关闭: 你的消息将只保留在本服。");
	}

	return Plugin_Handled;
}

public Action CommandCrAll(int client, int args)
{
	if (!CT_IsValidClient(client))
	{
		ReplyToCommand(client, "[CrossTalk] This command can only be used in-game.");
		return Plugin_Handled;
	}

	if (!CT_ClientCanAnnounce(client))
	{
		PrintToChat(client, "\x01[\x04CrossTalk\x01] \x02你没有权限使用跨服喊话。");
		return Plugin_Handled;
	}

	char argBuf[CT_MAX_MSG_LENGTH + 1];
	GetCmdArgString(argBuf, sizeof(argBuf));

	// 检查多余参数（供 !crall 无内容提示）
	if (args < 1 || CT_IsEmpty(argBuf))
	{
		PrintToChat(client, "\x01[\x04CrossTalk\x01] \x02用法: !crall <消息内容>");
		return Plugin_Handled;
	}

	// 净化
	char sanitized[CT_MAX_MSG_LENGTH + 1];
	CT_SanitizeMessage(argBuf, sanitized, sizeof(sanitized));
	if (CT_IsEmpty(sanitized))
	{
		PrintToChat(client, "\x01[\x04CrossTalk\x01] \x02用法: !crall <消息内容>");
		return Plugin_Handled;
	}

	char playerName[MAX_NAME_LENGTH];
	GetClientName(client, playerName, sizeof(playerName));

	// 写入共享 DB（异步）
	CT_DB_InsertMessage(gC_ServerId, gC_ServerName, playerName, "0", CT_MSG_TYPE_ANNOUNCE, sanitized);

	// 本服本地显示（HUD + 聊天框）
	CT_HUD_ShowAnnounce(gC_ServerName, playerName, sanitized);
	CT_Chat_ShowAnnounce(gC_ServerName, playerName, sanitized);

	CT_LogDebug("Announce from %s: %s", playerName, sanitized);

	return Plugin_Handled;
}
