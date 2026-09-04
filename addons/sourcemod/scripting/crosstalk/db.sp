/*
	CrossTalk - DB
	共享 SQLite 消息总线：连接、建表、写消息、轮询新消息、清理过期消息、server_state 维护。

	表结构:
	  messages(id INTEGER PRIMARY KEY AUTOINCREMENT,
	           server_id TEXT, server_name TEXT, player_name TEXT, steam_id TEXT,
	           msg_type INTEGER, content TEXT, created_at INTEGER)
	  server_state(server_id TEXT PRIMARY KEY, last_message_id INTEGER)

	跨服共享关键：
	  - 所有服务器必须指向同一个 sq3 文件（默认共享同一 data/ 目录时零配置）
	  - 驱动内置 busy_handler(100ms) 重试，多进程并发写安全
	  - 消息读多写少（每个服 0.5s 一次 SELECT），负载低
*/

// =====[ CONSTANTS ]=====

#define CT_MSG_TYPE_CHAT   0  // 玩家普通聊天
#define CT_MSG_TYPE_ANNOUNCE 1  // 管理员喊话

#define CT_DB_MAX_QUERY_ROWS 100  // 每轮询最多读取消息数
#define CT_DB_PATH_DEFAULT "file:addons/sourcemod/data/crosstalk/shared.sq3"  // 运行时替换为完整绝对路径

// =====[ STATE ]=====

Database gH_DB;
bool gB_DBReady;
int gI_LastReadId;      // 本服已读的最大消息 id
bool gB_Polling;        // 防止轮询重入
bool gB_CleanupPending; // 清理标记

// 将 SQLite URI 补全为"绝对可共享路径"（服务器根目录下 addons/sourcemod/data/...）
void CT_BuildDefaultDbPath(char[] buffer, int maxlength)
{
	// BuildPath(Path_SM, ...) 得到 <SM>/... 绝对路径，统一 file: 前缀
	char smPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, smPath, sizeof(smPath), "data/crosstalk/shared.sq3");
	Format(buffer, maxlength, "file:%s", smPath);
}

// =====[ PUBLIC ]=====

void CT_DB_Init()
{
	gB_DBReady = false;
	gI_LastReadId = 0;
	gB_Polling = false;

	char error[256];
	KeyValues kv = new KeyValues("");
	kv.SetString("driver", "sqlite");

	char dbPath[512];
	if (gCV_DbPath != null)
	{
		gCV_DbPath.GetString(dbPath, sizeof(dbPath));
	}

	char resolvedDbPath[512];
	char smPath[PLATFORM_MAX_PATH];

	if (dbPath[0] == '\0')
	{
		// 空 → 默认共享 DB（BuildPath 绝对路径，跨服在共享目录默认即互通）
		CT_BuildDefaultDbPath(resolvedDbPath, sizeof(resolvedDbPath));
	}
	else if (strncmp(dbPath, "file:", 5) == 0)
	{
		// file: 形式：直接使用（支持绝对路径或相对 SM 目录）
		strcopy(resolvedDbPath, sizeof(resolvedDbPath), dbPath);
	}
	else
	{
		// 相对路径（相对 SM 根目录）：补全为绝对 URI
		BuildPath(Path_SM, smPath, sizeof(smPath), "%s", dbPath);
		Format(resolvedDbPath, sizeof(resolvedDbPath), "file:%s", smPath);
	}

	kv.SetString("database", resolvedDbPath);
	CT_LogDebug("DB path: %s", resolvedDbPath);

	gH_DB = SQL_ConnectCustom(kv, error, sizeof(error), true);
	delete kv;

	if (gH_DB == null)
	{
		LogError("[CrossTalk] SQLite connect failed: %s", error);
		return;
	}

	CT_DB_EnsureSchema();
}

// 初始化表结构
void CT_DB_EnsureSchema()
{
	if (gH_DB == null)
	{
		return;
	}

	char query[1024];
	Format(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, server_id TEXT NOT NULL, server_name TEXT NOT NULL, player_name TEXT NOT NULL, steam_id TEXT NOT NULL, msg_type INTEGER NOT NULL DEFAULT 0, content TEXT NOT NULL, created_at INTEGER NOT NULL)");
	SQL_TQuery(gH_DB, CT_DB_Callback_Schema, query);

	Format(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS server_state (server_id TEXT PRIMARY KEY, last_message_id INTEGER NOT NULL DEFAULT 0)");
	SQL_TQuery(gH_DB, CT_DB_Callback_Schema, query);
}

public void CT_DB_Callback_Schema(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		LogError("[CrossTalk] Schema error: %s", error);
		return;
	}
	gB_DBReady = true;
	CT_DB_LoadLastRead();
	CT_LogDebug("DB ready, last_read=%d", gI_LastReadId);
}

// hostname / server_id 在 configs executed 后可能变化：重载已读位置
void CT_DB_RefreshServerIdentity()
{
	if (gH_DB == null || !gB_DBReady)
	{
		return;
	}
	CT_DB_LoadLastRead();
}

// 从 server_state 恢复本服已读位置
void CT_DB_LoadLastRead()
{
	char query[512];
	char escServerId[128];
	SQL_EscapeString(gH_DB, gC_ServerId, escServerId, sizeof(escServerId));
	Format(query, sizeof(query), "SELECT last_message_id FROM server_state WHERE server_id = '%s'", escServerId);
	SQL_TQuery(gH_DB, CT_DB_Callback_LoadLastRead, query);
}

public void CT_DB_Callback_LoadLastRead(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		LogError("[CrossTalk] Load last_read failed: %s", error);
		return;
	}
	if (results.FetchRow())
	{
		gI_LastReadId = results.FetchInt(0);
	}
	CT_LogDebug("last_read restored: %d", gI_LastReadId);
}

// 写入一条消息（异步，不阻塞主线程）
void CT_DB_InsertMessage(const char[] serverId, const char[] serverName,
						 const char[] playerName, const char[] steamId,
						 int msgType, const char[] content)
{
	if (gH_DB == null || !gB_DBReady)
	{
		LogError("[CrossTalk] DB not ready, dropping message");
		return;
	}

	// 参数化处理：所有字符串单引号转义
	char escServerId[128], escServerName[128], escPlayerName[128], escSteamId[128], escContent[512];
	SQL_EscapeString(gH_DB, serverId, escServerId, sizeof(escServerId));
	SQL_EscapeString(gH_DB, serverName, escServerName, sizeof(escServerName));
	SQL_EscapeString(gH_DB, playerName, escPlayerName, sizeof(escPlayerName));
	SQL_EscapeString(gH_DB, steamId, escSteamId, sizeof(escSteamId));
	SQL_EscapeString(gH_DB, content, escContent, sizeof(escContent));

	char out[2048];
	Format(out, sizeof(out),
		"INSERT INTO messages (server_id, server_name, player_name, steam_id, msg_type, content, created_at) VALUES ('%s', '%s', '%s', '%s', %d, '%s', %d)",
		escServerId, escServerName, escPlayerName, escSteamId, msgType, escContent, GetTime());

	// escContent 可能被截断到 512；消息内容限制 256 保证不超
	SQL_TQuery(gH_DB, CT_DB_Callback_Insert, out);
}

public void CT_DB_Callback_Insert(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		LogError("[CrossTalk] Insert failed: %s", error);
	}
}

// 轮询新消息（供 state.sp 的定时器调用）
void CT_DB_PollNewMessages()
{
	if (gH_DB == null || !gB_DBReady || gB_Polling)
	{
		return;
	}
	gB_Polling = true;

	char query[512];
	// 本服自身的消息由本地已显示，这里全取，渲染端跳过 server_id == 本服。
	// 为简单与不丢消息，全部拉取；server_id 相同消息在 state.sp 渲染时跳过。
	Format(query, sizeof(query),
		"SELECT id, server_id, server_name, player_name, msg_type, content FROM messages WHERE id > %d ORDER BY id ASC LIMIT %d",
		gI_LastReadId, CT_DB_MAX_QUERY_ROWS);
	SQL_TQuery(gH_DB, CT_DB_Callback_Poll, query);
}

public void CT_DB_Callback_Poll(Database db, DBResultSet results, const char[] error, any data)
{
	gB_Polling = false;
	if (error[0] != '\0')
	{
		LogError("[CrossTalk] Poll failed: %s", error);
		return;
	}

	int lastId = gI_LastReadId;
	while (results.FetchRow())
	{
		int id = results.FetchInt(0);
		char serverId[128];
		results.FetchString(1, serverId, sizeof(serverId));
		char serverName[128];
		results.FetchString(2, serverName, sizeof(serverName));
		char playerName[64];
		results.FetchString(3, playerName, sizeof(playerName));
		int msgType = results.FetchInt(4);
		char content[CT_MAX_MSG_LENGTH + 1];
		results.FetchString(5, content, sizeof(content));

		// 渲染（state.sp 分派到 chat.sp / hud.sp）
		CT_RenderIncomingMessage(serverId, serverName, playerName, msgType, content);

		if (id > lastId)
		{
			lastId = id;
		}
	}

	// 更新已读位置（无论是否拉到消息）
	if (lastId != gI_LastReadId)
	{
		gI_LastReadId = lastId;
		CT_DB_SaveLastRead(lastId);
	}
}

// 保存已读位置（异步 upsert）
void CT_DB_SaveLastRead(int lastId)
{
	char query[512];
	char escServerId[128];
	SQL_EscapeString(gH_DB, gC_ServerId, escServerId, sizeof(escServerId));
	Format(query, sizeof(query),
		"INSERT OR REPLACE INTO server_state (server_id, last_message_id) VALUES ('%s', %d)",
		escServerId, lastId);
	SQL_TQuery(gH_DB, CT_DB_Callback_SaveLastRead, query);
}

public void CT_DB_Callback_SaveLastRead(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
	{
		LogError("[CrossTalk] Save last_read failed: %s", error);
	}
}

// 清理过期消息（TTL 以外）
void CT_DB_Cleanup()
{
	if (gH_DB == null || !gB_DBReady || gB_CleanupPending)
	{
		return;
	}
	gB_CleanupPending = true;

	int ttlDays = gCV_MessageTtlDays != null ? gCV_MessageTtlDays.IntValue : 7;
	int cutoff = GetTime() - ttlDays * 86400;
	char query[512];
	Format(query, sizeof(query), "DELETE FROM messages WHERE created_at < %d", cutoff);
	SQL_TQuery(gH_DB, CT_DB_Callback_Cleanup, query);
}

public void CT_DB_Callback_Cleanup(Database db, DBResultSet results, const char[] error, any data)
{
	gB_CleanupPending = false;
	if (error[0] != '\0')
	{
		LogError("[CrossTalk] Cleanup failed: %s", error);
	}
	else
	{
		CT_LogDebug("Cleanup done");
	}
}

// 插件卸载/低内存时释放
// （持久连接由 SourceMod 自动释放，此处不再手动删除含 Handle 避免 double-free；保留供未来需要）
