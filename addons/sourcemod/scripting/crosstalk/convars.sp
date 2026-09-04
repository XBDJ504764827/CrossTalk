/*
	CrossTalk - ConVars & Cookie
	所有 ConVar 以 cross_talk_ 前缀命名；配置文件由 AutoExecConfig 生成到
	cfg/sourcemod/crosstalk.cfg（首次启动自动生成，已存在不覆盖）。
*/

// =====[ CVARS ]=====

ConVar gCV_Enabled;
ConVar gCV_DbPath;
ConVar gCV_ServerId;
ConVar gCV_PollInterval;
ConVar gCV_AnnounceFlag;
ConVar gCV_ChatColor;
ConVar gCV_AnnounceColor;
ConVar gCV_HudX;
ConVar gCV_HudY;
ConVar gCV_HudHoldTime;
ConVar gCV_HudR;
ConVar gCV_HudG;
ConVar gCV_HudB;
ConVar gCV_HudAlpha;
ConVar gCV_HudEffect;
ConVar gCV_HudFadeIn;
ConVar gCV_HudFadeOut;
ConVar gCV_MessageTtlDays;
ConVar gCV_CleanupInterval;
ConVar gCV_Debug;

// =====[ COOKIE ]=====

Cookie gH_CrossTalkCookie; // !cr 开关（每个玩家独立，持久化）

// =====[ GLOBAL STATE ]=====

char gC_ServerName[64];       // 当前服务器名（hostname，动态刷新）
char gC_ServerId[64];         // 服务器标识（默认 = hostname；ConVar 可覆盖）

// =====[ PUBLIC ]=====

void CT_CreateConVars()
{
	// SourceMod 原生配置：首次启动自动生成 cfg/sourcemod/crosstalk.cfg
	// 后续通过 autoexec 命令区执行（OnConfigsExecuted 时）
	AutoExecConfig(true, "crosstalk", "sourcemod");

	gCV_Enabled = CreateConVar("cross_talk_enabled", "1",
		"总开关：是否启用跨服聊天功能（0=完全禁用，含接收与渲染）。", _, true, 0.0, true, 1.0);
	gCV_DbPath = CreateConVar("cross_talk_db_path", "",
		"共享 SQLite 数据库（留空 = 默认 addons/sourcemod/data/sqlite/crosstalk/shared.sq3，所有服务器共享同一 data/ 目录时零配置互通。或填相对库名如 crosstalk/shared；或绝对路径 file:/绝对路径/xxx.sq3（需目录已存在）。所有服务器必须指向同一个文件才能互通）。");
	gCV_ServerId = CreateConVar("cross_talk_server_id", "",
		"服务器标识（用于消息来源与去重）。留空则自动使用 hostname 值。");
	gCV_PollInterval = CreateConVar("cross_talk_poll_interval", "0.5",
		"跨服消息轮询间隔（秒）。值越小延迟越低，数据库负载越高。", _, true, 0.1, true, 10.0);
	gCV_AnnounceFlag = CreateConVar("cross_talk_announce_flag", "b",
		"管理员喊话所需权限位（字母）。b=AdmFlag_Ban, c=Kick, d=Admin, g=Generic, l=Chat, o=Convar, z=Root。");
	gCV_ChatColor = CreateConVar("cross_talk_chat_color", "{default}",
		"跨服聊天显示颜色（sourcemod CSGO 颜色码，如 {default} {red} {green} {lime} {orange} {purple} {grey} {gold}）。");
	gCV_AnnounceColor = CreateConVar("cross_talk_announce_color", "{red}",
		"跨服喊话在聊天框中显示的颜色（如上）。");
	gCV_HudX = CreateConVar("cross_talk_hud_x", "-1.0",
		"HUD 弹屏水平位置（-1.0=居中，0=最左，1=最右）。", _, true, -1.0, true, 1.0);
	gCV_HudY = CreateConVar("cross_talk_hud_y", "0.1",
		"HUD 弹屏垂直位置（-1.0=居中，0=顶部，1=底部）。", _, true, -1.0, true, 1.0);
	gCV_HudHoldTime = CreateConVar("cross_talk_hud_holdtime", "5.0",
		"HUD 弹屏显示时长（秒）。", _, true, 0.0, true, 30.0);
	gCV_HudR = CreateConVar("cross_talk_hud_r", "255",
		"HUD 弹屏颜色 红色分量（0-255）。", _, true, 0.0, true, 255.0);
	gCV_HudG = CreateConVar("cross_talk_hud_g", "80",
		"HUD 弹屏颜色 绿色分量（0-255）。", _, true, 0.0, true, 255.0);
	gCV_HudB = CreateConVar("cross_talk_hud_b", "80",
		"HUD 弹屏颜色 蓝色分量（0-255）。", _, true, 0.0, true, 255.0);
	gCV_HudAlpha = CreateConVar("cross_talk_hud_alpha", "255",
		"HUD 弹屏透明度（0-255，255=不透明）。", _, true, 0.0, true, 255.0);
	gCV_HudEffect = CreateConVar("cross_talk_hud_effect", "1",
		"HUD 弹屏效果（0=淡入，1=闪烁，2=淡出）。", _, true, 0.0, true, 2.0);
	gCV_HudFadeIn = CreateConVar("cross_talk_hud_fadein", "0.5",
		"HUD 弹屏淡入时长（秒）。", _, true, 0.0, true, 10.0);
	gCV_HudFadeOut = CreateConVar("cross_talk_hud_fadeout", "0.5",
		"HUD 弹屏淡出时长（秒）。", _, true, 0.0, true, 10.0);
	gCV_MessageTtlDays = CreateConVar("cross_talk_message_ttl_days", "7",
		"消息保留天数（超期自动清理）。", _, true, 1.0, true, 90.0);
	gCV_CleanupInterval = CreateConVar("cross_talk_cleanup_interval", "300",
		"消息清理检查间隔（秒）。", _, true, 30.0, true, 3600.0);
	gCV_Debug = CreateConVar("cross_talk_debug", "0",
		"调试日志（1=详细）。", _, true, 0.0, true, 1.0);

	// Cookie：!cr 开关，跨服务器生效（存客户端本地）
	gH_CrossTalkCookie = RegClientCookie("crosstalk_cr_enabled",
		"CrossTalk: cross-server chat send enabled", CookieAccess_Protected);
}

// =====[ HELPERS ]=====

bool CT_IsEnabled()
{
	return gCV_Enabled != null && gCV_Enabled.BoolValue;
}

bool CT_IsDebug()
{
	return gCV_Debug != null && gCV_Debug.BoolValue;
}

void CT_LogDebug(const char[] format, any ...)
{
	if (!CT_IsDebug())
	{
		return;
	}
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogMessage("[CrossTalk] %s", buffer);
}
