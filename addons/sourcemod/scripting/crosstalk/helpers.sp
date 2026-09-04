/*
	CrossTalk - Helpers
	服务器名 / 客户端校验 / 消息净化 / 简易颜色渲染（内置轻量色码，零第三方依赖）。
*/

// =====[ CONSTANTS ]=====

#define CT_MAX_MSG_LENGTH 256

// =====[ PUBLIC ]=====

void CT_InitHelpers()
{
	CT_RefreshServerName();
}

// 刷新服务器名（hostname 实时读取；server_id 可被 ConVar 覆盖）
void CT_RefreshServerName()
{
	ConVar hostname = FindConVar("hostname");
	if (hostname != null)
	{
		hostname.GetString(gC_ServerName, sizeof(gC_ServerName));
	}
	else
	{
		gC_ServerName[0] = '\0';
	}

	if (gCV_ServerId != null)
	{
		gCV_ServerId.GetString(gC_ServerId, sizeof(gC_ServerId));
	}
	else
	{
		strcopy(gC_ServerId, sizeof(gC_ServerId), gC_ServerName);
	}
}

// 是否有效客户端（在游戏内、真人）
bool CT_IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

// 净化玩家输入的消息：剥离颜色码与换行，限制长度
void CT_SanitizeMessage(const char[] input, char[] output, int maxlength)
{
	strcopy(output, maxlength, input);
	// 剥离 SourceMod 颜色码（\x01-\x07 与 \x07FFFFxx 格式）
	char cleaned[CT_MAX_MSG_LENGTH + 1];
	int outIndex = 0;
	int len = strlen(output);
	for (int i = 0; i < len && outIndex < CT_MAX_MSG_LENGTH; i++)
	{
		char c = output[i];
		if (c == '\x01' || c == '\x02' || c == '\x03' || c == '\x04' ||
			c == '\x05' || c == '\x06' || c == '\x07')
		{
			// 8 位颜色码：\x07 + 6 hex（跳过 6 字符）
			if (c == '\x07' && i + 6 < len)
			{
				bool isHex = true;
				for (int j = 1; j <= 6; j++)
				{
					if (!IsCharNumeric(output[i + j]) &&
						!(output[i + j] >= 'a' && output[i + j] <= 'f') &&
						!(output[i + j] >= 'A' && output[i + j] <= 'F'))
					{
						isHex = false;
						break;
					}
				}
				if (isHex)
				{
					i += 6;
					continue;
				}
			}
			continue;
		}
		if (c == '\n' || c == '\r')
		{
			c = ' ';
		}
		cleaned[outIndex++] = c;
	}
	cleaned[outIndex] = '\0';
	strcopy(output, maxlength, cleaned);
}

// 消息是否以命令触发字符开头（'!' 或 '/'），命令不跨服转发
// 兼容前导空白（"! ssp"、"  /help" 等视为命令）
bool CT_IsCommand(const char[] message)
{
	int i = 0;
	while (message[i] == ' ' || message[i] == '\t')
	{
		i++;
	}
	return message[i] == '!' || message[i] == '/';
}

// 是否空消息
bool CT_IsEmpty(const char[] message)
{
	return message[0] == '\0';
}

// 聊天颜色码（sourcemod-colors 兼容，仅常用几种）
// 返回对应 chat color 前缀（含 \x07 完整色码）到 buffer
void CT_ApplyColor(const char[] colorName, char[] buffer, int maxlength)
{
	if (StrEqual(colorName, "{default}"))
	{
		Format(buffer, maxlength, "\x01");
	}
	else if (StrEqual(colorName, "{red}"))
	{
		Format(buffer, maxlength, "\x07FF4040");
	}
	else if (StrEqual(colorName, "{green}"))
	{
		Format(buffer, maxlength, "\x073EFF3E");
	}
	else if (StrEqual(colorName, "{lime}"))
	{
		Format(buffer, maxlength, "\x0700FF00");
	}
	else if (StrEqual(colorName, "{orange}"))
	{
		Format(buffer, maxlength, "\x07FFA500");
	}
	else if (StrEqual(colorName, "{purple}"))
	{
		Format(buffer, maxlength, "\x07800080");
	}
	else if (StrEqual(colorName, "{grey}") || StrEqual(colorName, "{gray}"))
	{
		Format(buffer, maxlength, "\x07CCCCCC");
	}
	else if (StrEqual(colorName, "{gold}"))
	{
		Format(buffer, maxlength, "\x07FFD700");
	}
	else if (StrEqual(colorName, "{darkred}"))
	{
		Format(buffer, maxlength, "\x078B0000");
	}
	else
	{
		Format(buffer, maxlength, "\x01");
	}
}

// =====[ ADMIN / PERMISSION ]=====

// 从字母 flag 解析 AdminFlag
bool CT_ParseFlag(const char[] flagStr, AdminFlag &flag)
{
	if (flagStr[0] == '\0')
	{
		return false;
	}
	// 支持单个字母
	return FindFlagByChar(flagStr[0], flag);
}
// 客户端是否有喊话权限（cross_talk_announce_flag 指定）
bool CT_ClientCanAnnounce(int client)
{
	AdminFlag flag;
	char flagStr[4];
	if (gCV_AnnounceFlag != null)
	{
		gCV_AnnounceFlag.GetString(flagStr, sizeof(flagStr));
	}
	else
	{
		strcopy(flagStr, sizeof(flagStr), "b");
	}
	if (CT_ParseFlag(flagStr, flag))
	{
		return CheckCommandAccess(client, "sm_crall", view_as<int>(flag));
	}
	return CheckCommandAccess(client, "sm_crall", ADMFLAG_CHAT);
}
