/*
	CrossTalk - HUD
	管理员喊话弹屏：SetHudTextParams + ShowSyncHudText（参考 Hud-Text-Message 参数体系，
	全部参数 ConVar 化）。喊话到达时所有玩家屏幕上弹出，持续约 5 秒。

	SetHudTextParams(x, y, holdTime, r, g, b, a, effect, effectDuration, fadeIn, fadeOut)
	  x/y      - 屏幕坐标（-1.0 居中）
	  effect   - 0 淡入, 1 闪烁, 2 淡出
*/

// =====[ STATE ]=====

Handle gH_HudSync;

// =====[ PUBLIC ]=====

void CT_HUD_Init()
{
	gH_HudSync = CreateHudSynchronizer();
}

// 喊话弹屏显示（所有玩家）
void CT_HUD_ShowAnnounce(const char[] serverName,
						 const char[] playerName, const char[] content)
{
	if (gH_HudSync == null)
	{
		return;
	}

	float x = gCV_HudX != null ? gCV_HudX.FloatValue : -1.0;
	float y = gCV_HudY != null ? gCV_HudY.FloatValue : 0.1;
	float holdTime = gCV_HudHoldTime != null ? gCV_HudHoldTime.FloatValue : 5.0;
	int r = gCV_HudR != null ? gCV_HudR.IntValue : 255;
	int g = gCV_HudG != null ? gCV_HudG.IntValue : 80;
	int b = gCV_HudB != null ? gCV_HudB.IntValue : 80;
	int alpha = gCV_HudAlpha != null ? gCV_HudAlpha.IntValue : 255;
	int effect = gCV_HudEffect != null ? gCV_HudEffect.IntValue : 1;
	float fadeIn = gCV_HudFadeIn != null ? gCV_HudFadeIn.FloatValue : 0.5;
	float fadeOut = gCV_HudFadeOut != null ? gCV_HudFadeOut.FloatValue : 0.5;

	SetHudTextParams(x, y, holdTime, r, g, b, alpha, effect, 0.0, fadeIn, fadeOut);

	char display[CT_MAX_MSG_LENGTH * 2 + 32];
	Format(display, sizeof(display), "[%s] %s: %s", serverName, playerName, content);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!CT_IsValidClient(i))
		{
			continue;
		}
		ShowSyncHudText(i, gH_HudSync, display);
	}
}
