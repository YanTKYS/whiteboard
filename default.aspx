<%@ Page Language="C#" ValidateRequest="false" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Security.Cryptography" %>
<%@ Import Namespace="System.Text" %>
<%@ Import Namespace="System.Text.RegularExpressions" %>
<%@ Import Namespace="System.Globalization" %>
<%@ Import Namespace="System.Web.Configuration" %>
<%-- Import AD library --%>
<%@ Import Namespace="System.DirectoryServices.AccountManagement" %>

<script runat="server">
    // ==========================================
    // Server-side code (C#)
    // ==========================================
    // Note: ValidateRequest is disabled because notes may legitimately contain
    // "<" or "&". Every stored value is HtmlEncode()d on save and the only other
    // input (the note id) is matched against NoteIdPattern before touching disk.

    private const int TITLE_MAX_LENGTH = 50;
    private const int BODY_MAX_LENGTH  = 400;
    private const int EXPIRE_DAYS      = 7;
    private const int AD_CACHE_MINUTES = 60;

    // Floors for the stored admin password material; anything weaker is
    // treated as misconfiguration and rejected outright.
    private const int MIN_PBKDF2_ITERATIONS = 100000;
    private const int MIN_SALT_BYTES        = 16;
    private const int MIN_HASH_BYTES        = 32;

    // The admin password is never stored in this file. An <appSettings> entry
    // supplied out-of-band (see secrets.config.sample) holds the PBKDF2
    // material; when it is absent, admin deletion is simply unavailable.
    private const string ADMIN_PASSWORD_SETTING = "AdminPassword";

    // Single source of truth for the sticky-note colors: the server whitelist,
    // the legend, the filter buttons and the post form are all built from this.
    private class ColorDef
    {
        public string Key;
        public string Label;
        public string ShortLabel;
        public ColorDef(string key, string label, string shortLabel)
        {
            Key = key; Label = label; ShortLabel = shortLabel;
        }
    }

    private static readonly ColorDef[] COLORS = {
        new ColorDef("yellow", "黄色（一般）",          "黄"),
        new ColorDef("blue",   "青色（通知・確認）",     "青"),
        new ColorDef("red",    "赤色（重要・緊急）",     "赤"),
        new ColorDef("green",  "緑色（イベント・その他）", "緑")
    };
    private const string DEFAULT_COLOR = "yellow";

    // Data file name: yyyyMMdd_<GUID>.json
    private static readonly Regex NoteIdPattern = new Regex(
        @"^\d{8}_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.json$",
        RegexOptions.CultureInvariant);

    // Files are written without a BOM so that plain text tools read them cleanly
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

    // Relative (not "~/") so the app also works as a plain virtual directory
    private string DataFolderPath { get { return Server.MapPath("./data/"); } }
    private string LogFolderPath  { get { return Server.MapPath("./logs/"); } }

    private const string BLOCK_ACCESS_CONFIG =
        "<?xml version=\"1.0\"?><configuration><system.webServer><handlers><clear /></handlers></system.webServer></configuration>";

    // Create a folder and place a web.config that blocks direct HTTP access
    private void EnsureProtectedFolder(string folderPath)
    {
        if (!Directory.Exists(folderPath)) Directory.CreateDirectory(folderPath);

        // Written separately from the folder creation: an existing folder that
        // lost its guard file (manual copy, restore, ...) gets it back.
        string guardFile = Path.Combine(folderPath, "web.config");
        if (!File.Exists(guardFile)) File.WriteAllText(guardFile, BLOCK_ACCESS_CONFIG, Utf8NoBom);
    }

    private static readonly object _logLock = new object();
    private void LogError(string source, Exception ex)
    {
        try
        {
            EnsureProtectedFolder(LogFolderPath);
            string logFile = Path.Combine(LogFolderPath, DateTime.Now.ToString("yyyyMM", CultureInfo.InvariantCulture) + ".log");
            string entry = string.Format("[{0}] [{1}] {2}: {3}\r\n",
                DateTime.Now.ToString("yyyy/MM/dd HH:mm:ss", CultureInfo.InvariantCulture),
                User.Identity.Name, source, ex.Message);
            lock (_logLock) { File.AppendAllText(logFile, entry, Utf8NoBom); }
        }
        catch { }
    }

    protected void Page_Load(object sender, EventArgs e)
    {
        Response.Cache.SetCacheability(HttpCacheability.NoCache);

        // Reject unauthenticated requests
        if (!User.Identity.IsAuthenticated)
        {
            Response.StatusCode = 401;
            Response.TrySkipIisCustomErrors = true;
            Response.Write("Windows認証が必要です。IISの設定を確認してください。");
            Response.End();
            return;
        }

        string action = Request["action"];
        if (string.IsNullOrEmpty(action)) return; // no action -> render the page

        // CSRF guard: jQuery sets this header on same-origin AJAX, while a
        // cross-site form post cannot set it without a CORS preflight.
        if (!IsAjaxRequest())
        {
            Response.StatusCode = 400;
            WriteError("不正なリクエストです。");
            Response.End();
            return;
        }

        switch (action)
        {
            case "save":   SaveNote(); break;
            case "load":   GetNotesAndCleanup(); break;
            case "delete": DeleteNote(); break;
            default:
                Response.StatusCode = 400;
                WriteError("不明なアクションです。");
                break;
        }
        Response.End();
    }

    private bool IsAjaxRequest()
    {
        return string.Equals(Request.Headers["X-Requested-With"], "XMLHttpRequest",
            StringComparison.OrdinalIgnoreCase);
    }

    // ---- JSON responses ----

    private void WriteJson(object payload)
    {
        Response.ContentType = "application/json";
        // Keep our JSON body instead of letting IIS swap in an error page
        Response.TrySkipIisCustomErrors = true;
        Response.Write(new JavaScriptSerializer().Serialize(payload));
    }

    private void WriteError(string message)
    {
        WriteJson(new { status = "error", message = message });
    }

    private void WriteSuccess()
    {
        WriteJson(new { status = "success" });
    }

    // ---- Helpers ----

    private static string GetValue(Dictionary<string, string> source, string key, string fallback)
    {
        string value;
        if (source != null && source.TryGetValue(key, out value) && !string.IsNullOrEmpty(value)) return value;
        return fallback;
    }

    // Extract author_id with fallback to legacy "author" key
    private static string GetAuthorId(Dictionary<string, string> noteObj)
    {
        return GetValue(noteObj, "author_id", GetValue(noteObj, "author", ""));
    }

    private static string NormalizeColor(string color)
    {
        foreach (ColorDef c in COLORS)
        {
            if (c.Key == color) return color;
        }
        return DEFAULT_COLOR;
    }

    // Strip domain prefix (e.g. DOMAIN\taro -> taro)
    private static string StripDomain(string name)
    {
        int idx = name.LastIndexOf('\\');
        return idx >= 0 ? name.Substring(idx + 1) : name;
    }

    // yyyyMMdd as a comparable integer, without going through string parsing
    private static int ToDateKey(DateTime date)
    {
        return date.Year * 10000 + date.Month * 100 + date.Day;
    }

    private static bool IsExpired(string fileName, int todayKey)
    {
        if (fileName.Length < 8) return false;

        int expireKey;
        if (!int.TryParse(fileName.Substring(0, 8), NumberStyles.None, CultureInfo.InvariantCulture, out expireKey)) return false;
        return expireKey < todayKey;
    }

    // Resolve AD display name; result is cached per user for AD_CACHE_MINUTES
    private string GetAdDisplayName(string domainUser)
    {
        if (string.IsNullOrEmpty(domainUser)) return "";

        string cacheKey = "adname_" + domainUser.ToLowerInvariant();
        string cached = HttpRuntime.Cache[cacheKey] as string;
        if (cached != null) return cached;

        string displayName = domainUser;
        try
        {
            string[] parts = domainUser.Split('\\');
            string username = (parts.Length == 2) ? parts[1] : domainUser;

            using (PrincipalContext ctx = new PrincipalContext(ContextType.Domain))
            using (UserPrincipal user = UserPrincipal.FindByIdentity(ctx, username))
            {
                if (user != null && !string.IsNullOrEmpty(user.DisplayName)) displayName = user.DisplayName;
            }
        }
        catch (Exception ex)
        {
            LogError("GetAdDisplayName", ex);
        }

        // Cache failures too, otherwise every request retries a dead lookup
        HttpRuntime.Cache.Insert(cacheKey, displayName, null,
            DateTime.Now.AddMinutes(AD_CACHE_MINUTES), System.Web.Caching.Cache.NoSlidingExpiration);
        return displayName;
    }

    // Verify the admin password against the PBKDF2 material in <appSettings>.
    // Stored form: "<iterations>$<salt-base64>$<hash-base64>" (see README).
    // A missing, empty or malformed value accepts no password at all, so an
    // unconfigured deployment loses admin deletion rather than opening it up.
    private bool IsAdminPassword(string password)
    {
        if (string.IsNullOrEmpty(password)) return false;

        string stored = WebConfigurationManager.AppSettings[ADMIN_PASSWORD_SETTING];
        if (string.IsNullOrEmpty(stored)) return false;

        try
        {
            string[] parts = stored.Split('$');
            if (parts.Length != 3) return false;

            int iterations;
            if (!int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out iterations)
                || iterations < MIN_PBKDF2_ITERATIONS) return false;

            byte[] salt = Convert.FromBase64String(parts[1]);
            byte[] expected = Convert.FromBase64String(parts[2]);
            if (salt.Length < MIN_SALT_BYTES || expected.Length < MIN_HASH_BYTES) return false;

            // The 3-argument constructor is PBKDF2-HMAC-SHA1; the overload that
            // selects SHA-256 only exists from .NET Framework 4.7.2 and we
            // target 4.7, so the iteration count carries the cost here.
            using (Rfc2898DeriveBytes pbkdf2 = new Rfc2898DeriveBytes(password, salt, iterations))
            {
                return FixedTimeEquals(pbkdf2.GetBytes(expected.Length), expected);
            }
        }
        catch (Exception ex)
        {
            // Malformed configuration, not a wrong password - worth recording
            LogError("IsAdminPassword", ex);
            return false;
        }
    }

    // Compare digests without leaking the match length through timing
    private static bool FixedTimeEquals(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return false;

        int diff = 0;
        for (int i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
        return diff == 0;
    }

    private static Dictionary<string, string> ReadNote(string filePath)
    {
        return new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(File.ReadAllText(filePath));
    }

    // 1. Save note
    private void SaveNote()
    {
        try
        {
            string title = (Request["title"] ?? "").Trim();
            string body  = (Request["body"] ?? "").Trim();
            string color = NormalizeColor(Request["color"]);

            if (title.Length == 0 || body.Length == 0)
            {
                Response.StatusCode = 400;
                WriteError("タイトルと内容は必須です。");
                return;
            }

            // The client also enforces this via maxlength, but that is bypassable
            if (title.Length > TITLE_MAX_LENGTH || body.Length > BODY_MAX_LENGTH)
            {
                Response.StatusCode = 400;
                WriteError(string.Format("タイトルは{0}文字、内容は{1}文字までです。", TITLE_MAX_LENGTH, BODY_MAX_LENGTH));
                return;
            }

            string currentUserId = User.Identity.Name;
            string displayName = GetAdDisplayName(currentUserId);

            title = HttpUtility.HtmlEncode(title);
            body = HttpUtility.HtmlEncode(body).Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", "<br>");

            DateTime now = DateTime.Now;
            DateTime expireDate = now.AddDays(EXPIRE_DAYS);
            string fileName = expireDate.ToString("yyyyMMdd", CultureInfo.InvariantCulture)
                + "_" + Guid.NewGuid().ToString() + ".json";

            var noteData = new
            {
                id = fileName,
                title = title,
                body = body,
                color = color,
                author_id = currentUserId, // used for delete auth
                author_name = displayName, // used for display
                post_date = now.ToString("yyyy/MM/dd HH:mm", CultureInfo.InvariantCulture),
                expire_disp = expireDate.ToString("MM/dd", CultureInfo.InvariantCulture)
            };

            EnsureProtectedFolder(DataFolderPath);
            File.WriteAllText(Path.Combine(DataFolderPath, fileName),
                new JavaScriptSerializer().Serialize(noteData), Utf8NoBom);

            WriteSuccess();
        }
        catch (Exception ex)
        {
            LogError("SaveNote", ex);
            Response.StatusCode = 500;
            WriteError("掲示に失敗しました。");
        }
    }

    // 2. Load notes and delete expired files on the fly
    private void GetNotesAndCleanup()
    {
        try
        {
            EnsureProtectedFolder(DataFolderPath);

            string currentUserId = User.Identity.Name;
            int todayKey = ToDateKey(DateTime.Now);
            List<object> notes = new List<object>();

            foreach (string file in Directory.GetFiles(DataFolderPath, "*.json"))
            {
                if (IsExpired(Path.GetFileName(file), todayKey))
                {
                    try { File.Delete(file); } catch (Exception ex) { LogError("Cleanup", ex); }
                    continue;
                }

                try
                {
                    Dictionary<string, string> noteObj = ReadNote(file);
                    string authorId = GetAuthorId(noteObj);

                    notes.Add(new
                    {
                        id = GetValue(noteObj, "id", Path.GetFileName(file)),
                        title = GetValue(noteObj, "title", ""),
                        body = GetValue(noteObj, "body", ""),
                        color = NormalizeColor(GetValue(noteObj, "color", DEFAULT_COLOR)),
                        post_date = GetValue(noteObj, "post_date", ""),
                        expire_disp = GetValue(noteObj, "expire_disp", ""),
                        author_disp = StripDomain(GetValue(noteObj, "author_name", authorId)),
                        is_mine = authorId.Length > 0 && authorId.Equals(currentUserId, StringComparison.OrdinalIgnoreCase)
                    });
                }
                catch (Exception ex) { LogError("GetNotesAndCleanup", ex); }
            }

            WriteJson(notes);
        }
        catch (Exception ex)
        {
            LogError("GetNotesAndCleanup", ex);
            Response.StatusCode = 500;
            WriteError("一覧の取得に失敗しました。");
        }
    }

    // 3. Delete note
    private void DeleteNote()
    {
        string targetId = Request["id"];

        // Path traversal guard: the id must look exactly like a generated file name
        if (string.IsNullOrEmpty(targetId) || !NoteIdPattern.IsMatch(targetId))
        {
            Response.StatusCode = 400;
            WriteError("IDが不正です。");
            return;
        }

        string filePath = Path.Combine(DataFolderPath, targetId);
        if (!File.Exists(filePath))
        {
            Response.StatusCode = 404;
            WriteError("既に削除されています");
            return;
        }

        try
        {
            string authorId = GetAuthorId(ReadNote(filePath));

            bool isMine = authorId.Length > 0
                && authorId.Equals(User.Identity.Name, StringComparison.OrdinalIgnoreCase);
            bool isAdmin = IsAdminPassword(Request["admin_pass"]);

            if (!isMine && !isAdmin)
            {
                Response.StatusCode = 403;
                WriteError("権限がありません。");
                return;
            }

            File.Delete(filePath);
            WriteSuccess();
        }
        catch (Exception ex)
        {
            LogError("DeleteNote", ex);
            Response.StatusCode = 500;
            WriteError("削除処理に失敗しました");
        }
    }
</script>

<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ほわいとぼーど - 伝言板</title>
<script src="./common/jquery-3.6.0.min.js"></script>
<style>
    /* ---- Base ---- */
    body { font-family: "Meiryo UI", sans-serif; background-color: #f4f7f6; margin: 0; color: #333; }

    /* ---- Header ---- */
    header { background-color: #0056b3; color: white; padding: 15px 25px; display: flex; align-items: center; box-shadow: 0 2px 5px rgba(0,0,0,0.15); transition: background-color 0.3s; }
    header.admin-active { background-color: #b71c1c; }
    .logo-main { font-size: 1.8rem; font-weight: bold; margin-right: 15px; }
    .logo-sub { font-size: 0.9rem; opacity: 0.85; border-left: 1px solid rgba(255,255,255,0.5); padding-left: 15px; }
    #admin-banner { display: none; font-size: 0.82rem; background: rgba(255,255,255,0.2); padding: 4px 12px; border-radius: 12px; margin-left: auto; letter-spacing: 0.03em; }
    header.admin-active #admin-banner { display: inline; }

    /* ---- Controls bar ---- */
    #controls { background: #fff; border-bottom: 1px solid #e0e0e0; padding: 8px 25px; display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between; }
    #legend { display: flex; gap: 16px; flex-wrap: wrap; }
    .legend-item { font-size: 0.78rem; color: #555; display: flex; align-items: center; gap: 5px; }
    .legend-dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
    .legend-dot.yellow { background: #fdd835; }
    .legend-dot.blue   { background: #2196f3; }
    .legend-dot.red    { background: #ef5350; }
    .legend-dot.green  { background: #66bb6a; }
    #toolbar { display: flex; gap: 16px; flex-wrap: wrap; align-items: center; }
    .ctrl-group { display: flex; align-items: center; gap: 5px; }
    .ctrl-label { font-size: 0.78rem; color: #888; white-space: nowrap; }
    .filter-btn, .sort-btn { padding: 3px 10px; border: 1px solid #ccc; border-radius: 12px; background: #f5f5f5; color: #555; font-size: 0.78rem; cursor: pointer; transition: all 0.15s; }
    .filter-btn.active       { border-color: #0056b3; background: #0056b3; color: #fff; }
    .filter-btn.active.yellow { border-color: #f9a825; background: #f9a825; color: #333; }
    .filter-btn.active.blue   { border-color: #1e88e5; background: #1e88e5; color: #fff; }
    .filter-btn.active.red    { border-color: #e53935; background: #e53935; color: #fff; }
    .filter-btn.active.green  { border-color: #43a047; background: #43a047; color: #fff; }
    .sort-btn.active { border-color: #0056b3; background: #e3f0ff; color: #0056b3; font-weight: bold; }

    /* ---- Board ---- */
    #board { padding: 25px; display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 25px; align-items: start; }

    /* ---- Notes ---- */
    .note { width: 100%; min-height: 200px; height: auto; box-shadow: 0 2px 5px rgba(0,0,0,0.1); padding: 15px; box-sizing: border-box; display: flex; flex-direction: column; transition: transform 0.2s, box-shadow 0.2s; position: relative; border-radius: 2px; }
    .note:hover { transform: translateY(-3px); z-index: 10; box-shadow: 0 5px 15px rgba(0,0,0,0.2); }
    .note.yellow { background-color: #fffde7; border-top: 4px solid #fdd835; }
    .note.blue   { background-color: #e3f2fd; border-top: 4px solid #2196f3; }
    .note.red    { background-color: #ffebee; border-top: 4px solid #ef5350; }
    .note.green  { background-color: #e8f5e9; border-top: 4px solid #66bb6a; }
    .note.expiring-soon { outline: 2px dashed #ff9800; outline-offset: -3px; }
    .note-meta { display: flex; justify-content: space-between; font-size: 0.75rem; color: #888; margin-bottom: 8px; border-bottom: 1px dashed #ccc; padding-bottom: 4px; }
    .note-title { font-weight: bold; font-size: 1.1rem; margin-bottom: 10px; overflow: hidden; max-height: 3em; line-height: 1.4; }
    .note-body { flex-grow: 1; font-size: 0.95rem; overflow-y: auto; line-height: 1.6; white-space: pre-wrap; word-break: break-all; margin-bottom: 8px; }
    .note-footer { display: flex; align-items: flex-end; margin-top: auto; gap: 8px; }
    .expiry-badge { font-size: 0.72rem; color: #e65100; background: #fff3e0; border-radius: 8px; padding: 2px 8px; white-space: nowrap; flex-shrink: 0; }
    .note-author { font-size: 0.8rem; color: #0056b3; font-weight: bold; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; text-align: right; }
    .btn-delete-mine { position: absolute; top: 5px; right: 5px; width: 24px; height: 24px; line-height: 24px; text-align: center; color: #999; cursor: pointer; font-weight: bold; font-size: 16px; background: rgba(255,255,255,0.8); border-radius: 50%; }
    .btn-delete-mine:hover { background: #f44336; color: white; }

    /* ---- Loading ---- */
    .loading-msg { color: #aaa; margin: 40px auto; text-align: center; width: 100%; font-size: 0.95rem; animation: pulse 1.4s ease-in-out infinite; }
    @keyframes pulse { 0%, 100% { opacity: 0.8; } 50% { opacity: 0.3; } }

    /* ---- Toast ---- */
    #toast-container { position: fixed; bottom: 110px; left: 50%; transform: translateX(-50%); z-index: 9999; display: flex; flex-direction: column; align-items: center; gap: 8px; pointer-events: none; }
    .toast { background: rgba(50,50,50,0.9); color: #fff; padding: 9px 22px; border-radius: 20px; font-size: 0.88rem; white-space: nowrap; animation: toastIn 0.25s ease forwards; }
    .toast.out { animation: toastOut 0.3s ease forwards; }
    @keyframes toastIn  { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
    @keyframes toastOut { from { opacity: 1; } to { opacity: 0; transform: translateY(-4px); } }

    /* ---- FAB / Admin toggle ---- */
    #admin-mode-toggle { position: fixed; bottom: 10px; left: 10px; font-size: 0.8rem; color: #ccc; cursor: pointer; }
    #fab-add { position: fixed; bottom: 40px; right: 40px; width: 64px; height: 64px; background-color: #0056b3; color: white; border-radius: 50%; text-align: center; line-height: 60px; font-size: 32px; box-shadow: 0 4px 10px rgba(0,0,0,0.3); cursor: pointer; z-index: 100; user-select: none; }
    #fab-add:hover { background-color: #004494; transform: scale(1.1); }

    /* ---- Modal ---- */
    .modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0,0,0,0.6); z-index: 200; justify-content: center; align-items: center; }
    .modal-content { background-color: white; width: 90%; max-width: 500px; padding: 25px; border-radius: 8px; box-shadow: 0 10px 25px rgba(0,0,0,0.3); }
    .form-group { margin-bottom: 15px; }
    label { display: block; margin-bottom: 5px; font-weight: bold; font-size: 0.9rem; }
    .field-footer { display: flex; justify-content: flex-end; margin-top: 3px; }
    .char-counter { font-size: 0.75rem; color: #bbb; }
    .char-counter.warn { color: #e65100; font-weight: bold; }
    input[type="text"], textarea, select, input[type="password"] { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; font-size: 1rem; }
    textarea { height: 120px; resize: vertical; font-family: inherit; }
    .btn-area { display: flex; justify-content: flex-end; align-items: center; gap: 8px; margin-top: 20px; }
    .btn-hint { font-size: 0.75rem; color: #bbb; margin-right: auto; }
    button { padding: 10px 20px; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; font-weight: bold; }
    .btn-cancel { background-color: #f0f0f0; color: #333; }
    .btn-submit { background-color: #0056b3; color: white; }
    .btn-danger { background-color: #d32f2f; color: white; }

    /* ---- Board status messages ---- */
    .board-msg { color: #777; margin: 40px auto; text-align: center; width: 100%; }
    .board-msg.error { color: #e53935; }
</style>
</head>
<body>

    <header>
        <div class="logo-main">ほわいとぼーど</div>
        <div class="logo-sub">伝言板</div>
        <div id="admin-banner">管理者削除モード</div>
    </header>

    <div id="controls">
        <div id="legend">
<% foreach (var c in COLORS) { %>
            <span class="legend-item"><span class="legend-dot <%= c.Key %>"></span><%= c.Label %></span>
<% } %>
        </div>
        <div id="toolbar">
            <div class="ctrl-group">
                <span class="ctrl-label">絞り込み：</span>
                <button class="filter-btn active" data-color="all">すべて</button>
<% foreach (var c in COLORS) { %>
                <button class="filter-btn <%= c.Key %>" data-color="<%= c.Key %>"><%= c.ShortLabel %></button>
<% } %>
            </div>
            <div class="ctrl-group">
                <span class="ctrl-label">並び順：</span>
                <button class="sort-btn active" data-sort="newest">新しい順</button>
                <button class="sort-btn" data-sort="oldest">古い順</button>
                <button class="sort-btn" data-sort="expiry">期限が近い順</button>
            </div>
        </div>
    </div>

    <div id="board"></div>
    <div id="fab-add" title="新規掲示">+</div>
    <div id="admin-mode-toggle" title="管理者削除">Admin</div>

    <div id="modal-post" class="modal-overlay">
        <div class="modal-content">
            <h3 style="margin-top:0;">新規掲示付け</h3>
            <p style="font-size:0.85rem; color:#d32f2f; background:#ffebee; padding:5px; border-radius:4px;">
                誰でも見られる場所に内容を貼ります。<br>
                内容は<%= EXPIRE_DAYS.ToString() %>日後に自動的に削除されます。
            </p>
            <div class="form-group">
                <label>タイトル</label>
                <input type="text" id="input-title" maxlength="<%= TITLE_MAX_LENGTH.ToString() %>" placeholder="例：クリスマス会参加のお知らせ">
                <div class="field-footer"><span class="char-counter" id="counter-title">0 / <%= TITLE_MAX_LENGTH.ToString() %></span></div>
            </div>
            <div class="form-group">
                <label>内容</label>
                <textarea id="input-body" maxlength="<%= BODY_MAX_LENGTH.ToString() %>" placeholder="内容を入力してください..."></textarea>
                <div class="field-footer"><span class="char-counter" id="counter-body">0 / <%= BODY_MAX_LENGTH.ToString() %></span></div>
            </div>
            <div class="form-group">
                <label>付箋の色</label>
                <select id="input-color">
<% foreach (var c in COLORS) { %>
                    <option value="<%= c.Key %>"><%= c.Label %></option>
<% } %>
                </select>
            </div>
            <div class="btn-area">
                <span class="btn-hint">Ctrl+Enter で送信</span>
                <button class="btn-cancel" id="btn-cancel-post">キャンセル</button>
                <button class="btn-submit" id="btn-save">掲示</button>
            </div>
        </div>
    </div>

    <div id="modal-admin-delete" class="modal-overlay">
        <div class="modal-content" style="max-width: 400px;">
            <h3 style="margin-top:0;">管理者強制削除</h3>
            <p>管理者パスワードを入力してください。</p>
            <input type="hidden" id="admin-target-id">
            <div class="form-group"><input type="password" id="admin-pass" placeholder="パスワード"></div>
            <div class="btn-area">
                <button class="btn-cancel" id="btn-cancel-admin-delete">キャンセル</button>
                <button class="btn-danger" id="btn-exec-admin-delete">削除実行</button>
            </div>
        </div>
    </div>

    <div id="toast-container"></div>

<script>
    $(document).ready(function () {
        var API = 'default.aspx';
        var TITLE_MAX = <%= TITLE_MAX_LENGTH.ToString() %>, BODY_MAX = <%= BODY_MAX_LENGTH.ToString() %>;
        var EXPIRING_SOON_DAYS = 2;
        var DAY_MS = 86400000;
        var DEFAULT_COLOR = '<%= DEFAULT_COLOR %>';

        var notesData    = [];
        var activeFilter = 'all';
        var activeSort   = 'newest';
        var adminMode    = false;

        // ---- Initial load ----
        loadNotes();

        // ---- Helpers ----
        function parseResponse(res) {
            if (typeof res !== 'string') return res;
            try { return JSON.parse(res); } catch (e) { return null; }
        }

        // Pull the server message out of a failed response, else use the fallback
        function errorMessage(xhr, fallback) {
            var data = parseResponse(xhr && xhr.responseText);
            return (data && data.message) ? data.message : fallback;
        }

        function apiPost(action, data) { return $.post(API + '?action=' + action, data); }

        function escapeHtml(text) {
            return String(text == null ? '' : text)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
        }

        function openModal(selector) { $(selector).css('display', 'flex'); }
        function closeModal(selector) { $(selector).hide(); }

        // ---- Toast ----
        function showToast(msg) {
            var $t = $('<div class="toast">').text(msg);
            $('#toast-container').append($t);
            setTimeout(function () {
                $t.addClass('out');
                setTimeout(function () { $t.remove(); }, 300);
            }, 2800);
        }

        // ---- Character counters ----
        function updateCounter($input, $counter, max) {
            var len = $input.val().length;
            $counter.text(len + ' / ' + max);
            $counter.toggleClass('warn', len > Math.floor(max * 0.8));
        }
        $('#input-title').on('input', function () { updateCounter($(this), $('#counter-title'), TITLE_MAX); });
        $('#input-body').on('input',  function () { updateCounter($(this), $('#counter-body'),  BODY_MAX);  });

        // ---- Post modal ----
        $('#fab-add').on('click', function () {
            $('#input-title').val('').trigger('input');
            $('#input-body').val('').trigger('input');
            $('#input-color').val(DEFAULT_COLOR);
            openModal('#modal-post');
            $('#input-title').focus();
        });
        $('#btn-cancel-post').on('click', function () { closeModal('#modal-post'); });

        // ---- Save ----
        $('#btn-save').on('click', function () {
            var title = $.trim($('#input-title').val()),
                body  = $.trim($('#input-body').val()),
                color = $('#input-color').val();
            if (!title || !body) { showToast('タイトルと内容は必須です。'); return; }

            var $btn = $(this);
            $btn.prop('disabled', true).text('保存中...');
            apiPost('save', { title: title, body: body, color: color })
                .done(function (res) {
                    var data = parseResponse(res);
                    // A 200 response can still carry status:"error" - keep the
                    // modal (and the typed text) open in that case.
                    if (data && data.status === 'success') {
                        closeModal('#modal-post');
                        loadNotes();
                        showToast('掲示しました');
                    } else {
                        showToast((data && data.message) || '掲示に失敗しました。');
                    }
                })
                .fail(function (xhr) { showToast(errorMessage(xhr, '掲示に失敗しました。')); })
                .always(function () { $btn.prop('disabled', false).text('掲示'); });
        });

        // ---- Delete (shared by the owner button and the admin dialog) ----
        function deleteNote(id, adminPass, onSuccess) {
            var payload = { id: id };
            if (adminPass) payload.admin_pass = adminPass;

            apiPost('delete', payload)
                .done(function (res) {
                    var data = parseResponse(res);
                    if (data && data.status === 'success') {
                        if (onSuccess) onSuccess();
                        loadNotes();
                        showToast('削除しました');
                    } else {
                        showToast((data && data.message) || '削除に失敗しました。');
                    }
                })
                .fail(function (xhr) { showToast(errorMessage(xhr, '削除に失敗しました。')); });
        }

        $(document).on('click', '.btn-delete-mine', function (e) {
            e.stopPropagation(); // prevent triggering admin-mode note click
            var id = $(this).data('id');
            if (confirm('この内容を削除しますか？')) deleteNote(id, null, null);
        });

        // ---- Admin mode ----
        $('#admin-mode-toggle').on('click', function () {
            adminMode = !adminMode;
            $('header').toggleClass('admin-active', adminMode);
            showToast(adminMode ? '管理者削除モード：ON' : '管理者削除モード：OFF');
        });

        $(document).on('click', '.note', function () {
            if (!adminMode) return;
            $('#admin-target-id').val($(this).data('id'));
            $('#admin-pass').val('');
            openModal('#modal-admin-delete');
            $('#admin-pass').focus();
        });

        $('#btn-cancel-admin-delete').on('click', function () { closeModal('#modal-admin-delete'); });

        $('#btn-exec-admin-delete').on('click', function () {
            deleteNote($('#admin-target-id').val(), $('#admin-pass').val(), function () {
                closeModal('#modal-admin-delete');
            });
        });

        // ---- Keyboard shortcuts ----
        $(document).on('keydown', function (e) {
            if (e.key === 'Escape') { $('.modal-overlay:visible').hide(); }
        });
        $('#input-body').on('keydown', function (e) {
            if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { $('#btn-save').trigger('click'); }
        });

        // ---- Filter ----
        $('.filter-btn').on('click', function () {
            var color = $(this).data('color');
            activeFilter = (color !== 'all' && color === activeFilter) ? 'all' : color;
            $('.filter-btn').removeClass('active');
            $('.filter-btn[data-color="' + activeFilter + '"]').addClass('active');
            renderNotes();
        });

        // ---- Sort ----
        $('.sort-btn').on('click', function () {
            activeSort = $(this).data('sort');
            $('.sort-btn').removeClass('active');
            $(this).addClass('active');
            renderNotes();
        });

        // ---- Close modal on overlay click ----
        $('.modal-overlay').on('click', function (e) { if (e.target === this) $(this).hide(); });

        // ---- Load (fetch) ----
        function loadNotes() {
            $('#board').html('<p class="loading-msg">読み込み中...</p>');
            $.getJSON(API + '?action=load', function (data) {
                notesData = data || [];
                renderNotes();
            }).fail(function () {
                $('#board').html('<p class="board-msg error">読み込みに失敗しました。ページを更新してください。</p>');
            });
        }

        // ---- Sorting ----
        function compare(a, b) { return a === b ? 0 : (a < b ? -1 : 1); }

        var SORTERS = {
            newest: function (a, b) { return compare(String(b.post_date || ''), String(a.post_date || '')); },
            oldest: function (a, b) { return compare(String(a.post_date || ''), String(b.post_date || '')); },
            // the id carries a yyyyMMdd prefix, so this is "closest expiry first"
            expiry: function (a, b) { return compare(String(a.id || ''), String(b.id || '')); }
        };

        // Days until the expiry date encoded in the file name (null if unparsable)
        function daysUntilExpiry(id, today) {
            var m = /^(\d{4})(\d{2})(\d{2})/.exec(String(id || ''));
            if (!m) return null;
            var expireDate = new Date(+m[1], +m[2] - 1, +m[3]);
            return Math.round((expireDate - today) / DAY_MS);
        }

        function noteHtml(item, today) {
            var daysLeft = daysUntilExpiry(item.id, today);
            var expiringSoon = daysLeft !== null && daysLeft >= 0 && daysLeft <= EXPIRING_SOON_DAYS;
            var expiryBadge = expiringSoon
                ? '<div class="expiry-badge">あと' + (daysLeft > 0 ? daysLeft + '日' : '本日') + '</div>'
                : '';
            var deleteBtn = item.is_mine
                ? '<div class="btn-delete-mine" data-id="' + escapeHtml(item.id) + '" title="削除">&times;</div>'
                : '';

            // title / body are stored HTML-encoded by the server, so they go in
            // as-is; everything else is escaped here.
            return '' +
                '<div class="note ' + escapeHtml(item.color) + (expiringSoon ? ' expiring-soon' : '') + '" data-id="' + escapeHtml(item.id) + '">' +
                    deleteBtn +
                    '<div class="note-meta"><span>' + escapeHtml(item.post_date) + '</span><span>掲載期限：' + escapeHtml(item.expire_disp) + '</span></div>' +
                    '<div class="note-title" title="' + item.title + '">' + item.title + '</div>' +
                    '<div class="note-body">' + item.body + '</div>' +
                    '<div class="note-footer">' + expiryBadge + '<div class="note-author">by ' + escapeHtml(item.author_disp) + '</div></div>' +
                '</div>';
        }

        // ---- Render (filter + sort + draw) ----
        function renderNotes() {
            var $board = $('#board');

            var filtered = activeFilter === 'all'
                ? notesData
                : notesData.filter(function (n) { return n.color === activeFilter; });

            if (filtered.length === 0) {
                $board.html('<p class="board-msg">現在、掲示されているものはありません。</p>');
                return;
            }

            var sorted = filtered.slice().sort(SORTERS[activeSort] || SORTERS.newest);
            var today = new Date(); today.setHours(0, 0, 0, 0);

            var html = $.map(sorted, function (item) { return noteHtml(item, today); }).join('');
            $board.html(html);
        }
    });
</script>
</body>
</html>
