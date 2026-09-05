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

	【重要：数据库连接方式（已从 sqlite 驱动源码确认）】
	  SM 的 sqlite 扩展编译时带 SQLITE_USE_URI，SqDriver::Connect 对 database 名：
	    - "file:xxx" 前缀 → 原样透传给 sqlite3_open（URI 模式），file:/绝对路径 可用
	    - 普通相对库名 → 落在 data/sqlite/<name>.sq3（驱动内部机制，本项目不采用）
	  => 默认用 file:<Path_SM>/data/crosstalk/shared.sq3 绝对 URI，DB 文件落在
	     <游戏根>/addons/sourcemod/data/crosstalk/shared.sq3（README 架构图所示路径）。
	  => 需要跨服共享同一文件：所有服务器共享同一 data/ 目录时零配置；
	     或显式配置 file:/绝对路径/xxx.sq3（目录由本插件自建）。
*/

// =====[ CONSTANTS ]=====

#define CT_MSG_TYPE_CHAT   0  // 玩家普通聊天
#define CT_MSG_TYPE_ANNOUNCE 1  // 管理员喊话

#define CT_DB_MAX_QUERY_ROWS 100  // 每轮询最多读取消息数

// =====[ STATE ]=====

Database gH_DB;
bool gB_DBReady;
int gI_LastReadId;      // 本服已读的最大消息 id
bool gB_Polling;        // 防止轮询重入
bool gB_CleanupPending; // 清理标记
int gI_PollingTicks;    // 轮询重入计数（自愈用）

// =====[ PATH / DIRECTORY HELPERS ]=====

// 把用户可配的 cross_talk_db_path 规范化为 sqlite3 可用的 URI / 库名。
// 前置知识（SM sqlite 驱动源码确认）：以 "file:" 开头的 database 名原样透传
// 给 sqlite3_open（本扩展带 SQLITE_USE_URI，绝对 URI 可用）；相对 file: URI
// 按进程 CWD 解析不可控，绝不放行。
// 规范化规则：
//   空                          → file:<SM>/data/crosstalk/shared.sq3（默认共享）
//   file:/绝对路径/xxx.sq3      → 原样透传（URI 成对）
//   file:相对路径               → 相对 <SM> 解析后拼回绝对 URI
//   普通相对路径 data/xxx       → file:<SM>/data/xxx
//   其它相对路径（含 v0.1.4 相对库名 "crosstalk/shared"）→ file:<SM>/<值>
void CT_NormalizeDbUri(const char[] dbPath, char[] output, int maxlength)
{
	if (dbPath[0] == '\0')
	{
		char abs[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, abs, sizeof(abs), "data/crosstalk/shared.sq3");
		Format(output, maxlength, "file:%s", abs);
		return;
	}
	if (strncmp(dbPath, "file:/", 6) == 0)
	{
		// 绝对 URI：透明传递
		strcopy(output, maxlength, dbPath);
		return;
	}
	if (strncmp(dbPath, "file:", 5) == 0)
	{
		// 相对 URI（file:xxx）→ 相对 Path_SM 解析
		char rel[PLATFORM_MAX_PATH];
		strcopy(rel, sizeof(rel), dbPath[5]);
		if (strncmp(rel, "addons/sourcemod/", 17) == 0)
		{
			strcopy(rel, sizeof(rel), rel[17]); // 剥离重复前缀（Path_SM 已含）
		}
		BuildPath(Path_SM, output, maxlength, "file:%s", rel);
		return;
	}
	// 普通相对路径：相对 <SM> 解析（v0.1.4 相对库名如 "crosstalk/shared" 同样落此分支）
	BuildPath(Path_SM, output, maxlength, "file:%s", dbPath);
}

// 确保 file: URI 指向的父目录存在（SQLite 只建文件不建目录）。
// 权限 = 0o755 & ~umask（umask 0077 时仅属主可进，其他账号无法访问，
// 需要时手动 chmod 或在启动脚本里设 umask 022）。
static void CT_EnsureDbDir(const char[] dbUri)
{
	char filePath[PLATFORM_MAX_PATH];
	strcopy(filePath, sizeof(filePath), dbUri[5]); // 剥离 "file:"

	int last = FindCharInString(filePath, '/', true);
	if (last <= 0)
	{
		return;
	}
	filePath[last] = '\0';

	// 逐级创建（CreateDirectory 一次只建一级），DirExists 先行规避已存在误报。
	// CreateDirectory 原生路径相对游戏根（与 BuildPath 相对结果一致），可直接用。
	// 权限注意：SourcePawn 无 0755 八进制字面量，直接写 0755 会按十进制 755
	// （= 0o1363，即 d-wxrw---t）落盘。目标 0o755 必须写十进制 493。
	// 实际权限再经进程 umask 过滤（0022 → 0755；0077 → 0700 仅属主可进）。
	char partial[PLATFORM_MAX_PATH];
	int len = strlen(filePath);
	for (int i = 1; i < len; i++)
	{
		if (filePath[i] != '/')
		{
			continue;
		}
		strcopy(partial, i + 1, filePath);
		if (!DirExists(partial) && !CreateDirectory(partial, 493))
		{
			LogError("[CrossTalk] Could not create directory: %s", partial);
			return;
		}
	}
	if (!DirExists(filePath) && !CreateDirectory(filePath, 493))
	{
		LogError("[CrossTalk] Could not create directory: %s", filePath);
		return;
	}
	CT_LogDebug("DB dir ensured: %s", filePath);
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
	TrimString(dbPath);

	// 规范化为 sqlite3 可用的 file: URI
	char dbUri[PLATFORM_MAX_PATH];
	CT_NormalizeDbUri(dbPath, dbUri, sizeof(dbUri));
	kv.SetString("database", dbUri);
	CT_LogDebug("DB uri: %s", dbUri);

	// SQLite 只建文件不建目录；连接前自建父目录（权限 0755 & umask）
	CT_EnsureDbDir(dbUri);

	gH_DB = SQL_ConnectCustom(kv, error, sizeof(error), true);
	delete kv;

	if (gH_DB == null)
	{
		// 详细失败日志：ConVar 原始值 + 规范化 URI + 驱动错误
		LogError("[CrossTalk] SQLite connect failed: %s", error);
		LogError("[CrossTalk]   convar cross_talk_db_path='%s'", dbPath);
		LogError("[CrossTalk]   database uri='%s'", dbUri);
		{
			char probe[PLATFORM_MAX_PATH];
			strcopy(probe, sizeof(probe), dbUri[5]);
			LogError("[CrossTalk]   target file='%s'", probe);
			int last = FindCharInString(probe, '/', true);
			if (last > 0)
			{
				probe[last] = '\0';
			}
			LogError("[CrossTalk]   parent dir exists=%d (check owner & permissions; game process must be able to write)",
				DirExists(probe));
		}
		LogError("[CrossTalk]   hint: leave cross_talk_db_path empty for default shared database");
		LogError("[CrossTalk]   hint: relative URIs resolve against the game process CWD; if this server's CWD differs from the game root (common with panels/daemons), set an absolute path: cross_talk_db_path \"file:/absolute/path/to/csgo/addons/sourcemod/data/crosstalk/shared.sq3\" (all servers must share the same file; check CWD: ls -l /proc/$(pgrep srcds_linux)/cwd)");
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
	if (gH_DB == null || !gB_DBReady)
	{
		return;
	}
	if (gB_Polling)
	{
		// 自愈：异步回调丢失（如换图/关闭中）会卡死重入标志，超时强制放行
		gI_PollingTicks++;
		if (gI_PollingTicks < 40) // 40 × 0.5s = 20s
		{
			return;
		}
		LogError("[CrossTalk] Poll callback stuck >20s, forcing re-poll");
	}
	gB_Polling = true;
	gI_PollingTicks = 0;

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
	gI_PollingTicks = 0;
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
