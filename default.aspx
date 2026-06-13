<%@ Page Language="C#" Debug="true" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Security.Cryptography" %>
<%@ Import Namespace="System.Text" %>
<%-- Import AD library --%>
<%@ Import Namespace="System.DirectoryServices.AccountManagement" %>

<script runat="server">
    // ==========================================
    // Server-side code (C#)
    // ==========================================

    private string DataFolderPath { get { return Server.MapPath("./data/"); } }
    private string LogFolderPath  { get { return Server.MapPath("./logs/"); } }

    // Admin password hash (plain: admin9999)
    private const string MASTER_PASS_HASH = "240be518fabd2724ddb6f04eebdd92bd6073057426a7013d8519520743b08272";

    private static readonly string[] VALID_COLORS = { "yellow", "blue", "red", "green" };

    // Create a folder and place a web.config that blocks direct HTTP access
    private void EnsureProtectedFolder(string folderPath)
    {
        if (!Directory.Exists(folderPath))
        {
            Directory.CreateDirectory(folderPath);
            File.WriteAllText(
                Path.Combine(folderPath, "web.config"),
                "<?xml version=\"1.0\"?><configuration><system.webServer><handlers><clear /></handlers></system.webServer></configuration>"
            );
        }
    }

    private void EnsureDataFolder() { EnsureProtectedFolder(DataFolderPath); }

    private static readonly object _logLock = new object();
    private void LogError(string source, Exception ex)
    {
        try
        {
            EnsureProtectedFolder(LogFolderPath);
            string logFile = Path.Combine(LogFolderPath, DateTime.Now.ToString("yyyyMM") + ".log");
            string entry = string.Format("[{0}] [{1}] {2}: {3}\r\n",
                DateTime.Now.ToString("yyyy/MM/dd HH:mm:ss"), User.Identity.Name, source, ex.Message);
            lock (_logLock) { File.AppendAllText(logFile, entry, Encoding.UTF8); }
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
            Response.Write("Windows認証が必要です。IISの設定を確認してください。");
            Response.End();
            return;
        }

        string action = Request["action"];

        if (action == "save") SaveNote();
        else if (action == "load") GetNotesAndCleanup();
        else if (action == "delete") DeleteNote();
    }

    // Resolve AD display name; result is cached per user for 60 min
    private string GetAdDisplayName(string domainUser)
    {
        string cacheKey = "adname_" + domainUser.ToLowerInvariant();
        string cached = HttpRuntime.Cache[cacheKey] as string;
        if (cached != null) return cached;

        try
        {
            string[] parts = domainUser.Split('\\');
            if (parts.Length != 2) return domainUser;

            string username = parts[1];

            using (PrincipalContext ctx = new PrincipalContext(ContextType.Domain))
            {
                UserPrincipal user = UserPrincipal.FindByIdentity(ctx, username);
                if (user != null && !string.IsNullOrEmpty(user.DisplayName))
                {
                    HttpRuntime.Cache.Insert(cacheKey, user.DisplayName, null,
                        DateTime.Now.AddMinutes(60), System.Web.Caching.Cache.NoSlidingExpiration);
                    return user.DisplayName;
                }
            }
        }
        catch (Exception ex)
        {
            LogError("GetAdDisplayName", ex);
        }
        return domainUser;
    }

    // Extract author_id with fallback to legacy "author" key
    private static string GetAuthorId(Dictionary<string, string> noteObj)
    {
        if (noteObj.ContainsKey("author_id")) return noteObj["author_id"];
        if (noteObj.ContainsKey("author"))    return noteObj["author"];
        return "";
    }

    // SHA-256 hash helper
    private string ComputeSha256Hash(string rawData)
    {
        using (SHA256 sha256Hash = SHA256.Create())
        {
            byte[] bytes = sha256Hash.ComputeHash(Encoding.UTF8.GetBytes(rawData));
            StringBuilder builder = new StringBuilder();
            for (int i = 0; i < bytes.Length; i++) builder.Append(bytes[i].ToString("x2"));
            return builder.ToString();
        }
    }

    // 1. Save note
    private void SaveNote()
    {
        try
        {
            string title = Request["title"];
            string body = Request["body"];
            string color = Request["color"];
            if (Array.IndexOf(VALID_COLORS, color) < 0) color = "yellow";

            string currentUserId = User.Identity.Name;

            if (string.IsNullOrEmpty(title) || string.IsNullOrEmpty(body))
            {
                Response.Write("{\"status\":\"error\",\"message\":\"title and body are required.\"}");
                Response.End();
                return;
            }

            string displayName = GetAdDisplayName(currentUserId);

            title = HttpUtility.HtmlEncode(title);
            body = HttpUtility.HtmlEncode(body).Replace("\n", "<br>");

            DateTime expireDate = DateTime.Now.AddDays(7);
            string fileName = expireDate.ToString("yyyyMMdd") + "_" + Guid.NewGuid().ToString() + ".json";

            var noteData = new
            {
                id = fileName,
                title = title,
                body = body,
                color = color,
                author_id = currentUserId, // used for delete auth
                author_name = displayName, // used for display
                post_date = DateTime.Now.ToString("yyyy/MM/dd HH:mm"),
                expire_disp = expireDate.ToString("MM/dd")
            };

            JavaScriptSerializer serializer = new JavaScriptSerializer();
            string jsonContent = serializer.Serialize(noteData);

            EnsureDataFolder();
            File.WriteAllText(Path.Combine(DataFolderPath, fileName), jsonContent);

            Response.ContentType = "application/json";
            Response.Write("{\"status\":\"success\"}");
        }
        catch (Exception ex)
        {
            LogError("SaveNote", ex);
            Response.StatusCode = 500;
            Response.Write(new JavaScriptSerializer().Serialize(new { status = "error", message = ex.Message }));
        }
        Response.End();
    }

    // 2. Load notes and delete expired files on the fly
    private void GetNotesAndCleanup()
    {
        List<object> notes = new List<object>();
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        string currentUserId = User.Identity.Name;

        EnsureDataFolder();

        string[] files = Directory.GetFiles(DataFolderPath, "*.json");
        string todayStr = DateTime.Now.ToString("yyyyMMdd");
        int todayInt = int.Parse(todayStr);

        foreach (string file in files)
        {
            string fileName = Path.GetFileName(file);
            if (fileName.Length > 8)
            {
                string datePart = fileName.Substring(0, 8);
                int expireDateInt;
                if (int.TryParse(datePart, out expireDateInt))
                {
                    if (expireDateInt < todayInt)
                    {
                        try { File.Delete(file); } catch { }
                        continue;
                    }
                }
            }

            try
            {
                string content = File.ReadAllText(file);
                var noteObj = serializer.Deserialize<Dictionary<string, string>>(content);

                string authorId = GetAuthorId(noteObj);

                string authorName = noteObj.ContainsKey("author_name") ? noteObj["author_name"] : authorId;
                // Strip domain prefix (e.g. DOMAIN\taro -> taro)
                int bsIdx = authorName.LastIndexOf('\\');
                if (bsIdx >= 0) authorName = authorName.Substring(bsIdx + 1);

                bool isMine = authorId.Equals(currentUserId, StringComparison.OrdinalIgnoreCase);

                var responseObj = new {
                    id = noteObj["id"],
                    title = noteObj["title"],
                    body = noteObj["body"],
                    color = noteObj["color"],
                    post_date = noteObj["post_date"],
                    expire_disp = noteObj["expire_disp"],
                    author_disp = authorName,
                    is_mine = isMine
                };

                notes.Add(responseObj);
            }
            catch (Exception ex) { LogError("GetNotesAndCleanup", ex); }
        }

        Response.ContentType = "application/json";
        Response.Write(serializer.Serialize(notes));
        Response.End();
    }

    // 3. Delete note
    private void DeleteNote()
    {
        string targetId = Request["id"];
        string adminPass = Request["admin_pass"];
        string currentUserId = User.Identity.Name;

        // Path traversal guard: strip directory components and validate format
        string safeId = Path.GetFileName(targetId ?? "");
        if (safeId != targetId || !safeId.EndsWith(".json") || safeId.Length < 10)
        {
            Response.Write("{\"status\":\"error\",\"message\":\"Invalid ID.\"}");
            Response.End();
            return;
        }

        string filePath = Path.Combine(DataFolderPath, safeId);
        Response.ContentType = "application/json";

        if (File.Exists(filePath))
        {
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                string content = File.ReadAllText(filePath);
                var noteObj = serializer.Deserialize<Dictionary<string, string>>(content);

                string authorId = GetAuthorId(noteObj);

                bool isMine = authorId.Equals(currentUserId, StringComparison.OrdinalIgnoreCase);
                bool isAdmin = (!string.IsNullOrEmpty(adminPass) && ComputeSha256Hash(adminPass) == MASTER_PASS_HASH);

                if (isMine || isAdmin)
                {
                    File.Delete(filePath);
                    Response.Write("{\"status\":\"success\"}");
                }
                else
                {
                    Response.Write("{\"status\":\"error\", \"message\":\"権限がありません。\"}");
                }
            }
            catch (Exception ex)
            {
                LogError("DeleteNote", ex);
                Response.Write("{\"status\":\"error\", \"message\":\"削除処理に失敗しました\"}");
            }
        }
        else
        {
            Response.Write("{\"status\":\"error\", \"message\":\"既に削除されています\"}");
        }
        Response.End();
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
            <span class="legend-item"><span class="legend-dot yellow"></span>黄色（一般）</span>
            <span class="legend-item"><span class="legend-dot blue"></span>青色（通知・確認）</span>
            <span class="legend-item"><span class="legend-dot red"></span>赤色（重要・緊急）</span>
            <span class="legend-item"><span class="legend-dot green"></span>緑色（イベント・その他）</span>
        </div>
        <div id="toolbar">
            <div class="ctrl-group">
                <span class="ctrl-label">絞り込み：</span>
                <button class="filter-btn active" data-color="all">すべて</button>
                <button class="filter-btn yellow" data-color="yellow">黄</button>
                <button class="filter-btn blue"   data-color="blue">青</button>
                <button class="filter-btn red"    data-color="red">赤</button>
                <button class="filter-btn green"  data-color="green">緑</button>
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
                内容は7日後に自動的に削除されます。
            </p>
            <div class="form-group">
                <label>タイトル</label>
                <input type="text" id="input-title" maxlength="50" placeholder="例：クリスマス会参加のお知らせ">
                <div class="field-footer"><span class="char-counter" id="counter-title">0 / 50</span></div>
            </div>
            <div class="form-group">
                <label>内容</label>
                <textarea id="input-body" maxlength="400" placeholder="内容を入力してください..."></textarea>
                <div class="field-footer"><span class="char-counter" id="counter-body">0 / 400</span></div>
            </div>
            <div class="form-group">
                <label>付箋の色</label>
                <select id="input-color">
                    <option value="yellow">黄色（一般）</option>
                    <option value="blue">青色（通知・確認）</option>
                    <option value="red">赤色（重要・緊急）</option>
                    <option value="green">緑色（イベント・その他）</option>
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
                <button class="btn-cancel" onclick="$('#modal-admin-delete').hide()">キャンセル</button>
                <button class="btn-danger" id="btn-exec-admin-delete">削除実行</button>
            </div>
        </div>
    </div>

    <div id="toast-container"></div>

<script>
    $(document).ready(function() {
        var notesData   = [];
        var activeFilter = 'all';
        var activeSort   = 'newest';
        var adminMode    = false;
        var TITLE_MAX = 50, BODY_MAX = 400;

        // ---- Initial load ----
        loadNotes();

        // ---- Helpers ----
        function parseResponse(res) { return (typeof res === 'string') ? JSON.parse(res) : res; }

        // ---- Toast ----
        function showToast(msg) {
            var $t = $('<div class="toast">').text(msg);
            $('#toast-container').append($t);
            setTimeout(function() {
                $t.addClass('out');
                setTimeout(function() { $t.remove(); }, 300);
            }, 2800);
        }

        // ---- Character counters ----
        function updateCounter($input, $counter, max) {
            var len = $input.val().length;
            $counter.text(len + ' / ' + max);
            $counter.toggleClass('warn', len > Math.floor(max * 0.8));
        }
        $('#input-title').on('input', function() { updateCounter($(this), $('#counter-title'), TITLE_MAX); });
        $('#input-body').on('input',  function() { updateCounter($(this), $('#counter-body'),  BODY_MAX);  });

        // ---- Cancel buttons ----
        $('#btn-cancel-post').on('click', function() { $('#modal-post').hide(); });

        // ---- FAB ----
        $('#fab-add').on('click', function() {
            $('#input-title').val('').trigger('input');
            $('#input-body').val('').trigger('input');
            $('#input-color').val('yellow');
            $('#modal-post').css('display', 'flex');
            $('#input-title').focus();
        });

        // ---- Save ----
        $('#btn-save').on('click', function() {
            var title = $('#input-title').val(), body = $('#input-body').val(), color = $('#input-color').val();
            if (!title || !body) { showToast('タイトルと内容は必須です。'); return; }
            var $btn = $(this); $btn.prop('disabled', true).text('保存中...');
            $.post('Default.aspx?action=save', { title: title, body: body, color: color }, function() {
                $('#modal-post').hide();
                loadNotes();
                showToast('掲示しました');
            }).fail(function(xhr) {
                showToast('エラーが発生しました。');
                console.error(xhr.responseText);
            }).always(function() { $btn.prop('disabled', false).text('掲示'); });
        });

        // ---- Delete own note ----
        $(document).on('click', '.btn-delete-mine', function(e) {
            e.stopPropagation(); // prevent triggering admin-mode note click
            var id = $(this).data('id');
            if (confirm('この内容を削除しますか？')) {
                $.post('Default.aspx?action=delete', { id: id }, function(res) {
                    var data = parseResponse(res);
                    if (data.status === 'success') { loadNotes(); showToast('削除しました'); }
                    else { showToast(data.message); }
                });
            }
        });

        // ---- Admin mode ----
        $('#admin-mode-toggle').on('click', function() {
            adminMode = !adminMode;
            $('header').toggleClass('admin-active', adminMode);
            showToast(adminMode ? '管理者削除モード：ON' : '管理者削除モード：OFF');
        });

        $(document).on('click', '.note', function() {
            if (!adminMode) return;
            $('#admin-target-id').val($(this).data('id'));
            $('#admin-pass').val('');
            $('#modal-admin-delete').css('display', 'flex');
        });

        $('#btn-exec-admin-delete').on('click', function() {
            var id = $('#admin-target-id').val(), pass = $('#admin-pass').val();
            $.post('Default.aspx?action=delete', { id: id, admin_pass: pass }, function(res) {
                var data = parseResponse(res);
                if (data.status === 'success') { $('#modal-admin-delete').hide(); loadNotes(); showToast('削除しました'); }
                else { showToast(data.message); }
            });
        });

        // ---- Keyboard shortcuts ----
        $(document).on('keydown', function(e) {
            if (e.key === 'Escape') { $('.modal-overlay:visible').hide(); }
        });
        $('#input-body').on('keydown', function(e) {
            if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { $('#btn-save').trigger('click'); }
        });

        // ---- Filter ----
        $('.filter-btn').on('click', function() {
            var color = $(this).data('color');
            activeFilter = (color !== 'all' && color === activeFilter) ? 'all' : color;
            $('.filter-btn').removeClass('active');
            $('.filter-btn[data-color="' + activeFilter + '"]').addClass('active');
            renderNotes();
        });

        // ---- Sort ----
        $('.sort-btn').on('click', function() {
            activeSort = $(this).data('sort');
            $('.sort-btn').removeClass('active');
            $(this).addClass('active');
            renderNotes();
        });

        // ---- Close modal on overlay click ----
        $('.modal-overlay').on('click', function(e) { if (e.target === this) $(this).hide(); });

        // ---- Load (fetch) ----
        function loadNotes() {
            $('#board').html('<p class="loading-msg">読み込み中...</p>');
            $.getJSON('Default.aspx?action=load', function(data) {
                notesData = data;
                renderNotes();
            }).fail(function() {
                $('#board').html('<p class="board-msg error">読み込みに失敗しました。ページを更新してください。</p>');
            });
        }

        // ---- Render (filter + sort + draw) ----
        function renderNotes() {
            var $board = $('#board');
            $board.empty();

            var filtered = activeFilter === 'all'
                ? notesData
                : notesData.filter(function(n) { return n.color === activeFilter; });

            var sorted = filtered.slice().sort(function(a, b) {
                if (activeSort === 'newest') return a.post_date < b.post_date ? 1 : -1;
                if (activeSort === 'oldest') return a.post_date > b.post_date ? 1 : -1;
                if (activeSort === 'expiry') return a.id > b.id ? 1 : -1; // yyyyMMdd prefix
                return 0;
            });

            if (sorted.length === 0) {
                $board.html('<p class="board-msg">現在、掲示されているものはありません。</p>');
                return;
            }

            var today = new Date(); today.setHours(0, 0, 0, 0);

            $.each(sorted, function(i, item) {
                // Expiry warning: parse yyyyMMdd from file id
                var es = item.id.substring(0, 8);
                var expireDate = new Date(+es.substring(0,4), +es.substring(4,6)-1, +es.substring(6,8));
                var daysLeft = Math.ceil((expireDate - today) / 86400000);
                var expiringSoon = daysLeft >= 0 && daysLeft <= 2;
                var expiryBadge = expiringSoon
                    ? '<div class="expiry-badge">あと' + (daysLeft > 0 ? daysLeft + '日' : '本日') + '</div>'
                    : '';

                var noteClass = 'note ' + item.color + (expiringSoon ? ' expiring-soon' : '');
                var deleteBtn = item.is_mine
                    ? '<div class="btn-delete-mine" data-id="' + item.id + '" title="削除">&times;</div>'
                    : '';

                var html =
                    '<div class="' + noteClass + '" data-id="' + item.id + '">' +
                        deleteBtn +
                        '<div class="note-meta"><span>' + item.post_date + '</span><span>掲載期限：' + item.expire_disp + '</span></div>' +
                        '<div class="note-title" title="' + item.title + '">' + item.title + '</div>' +
                        '<div class="note-body">' + item.body + '</div>' +
                        '<div class="note-footer">' + expiryBadge + '<div class="note-author">by ' + item.author_disp + '</div></div>' +
                    '</div>';
                $board.append(html);
            });
        }
    });
</script>
</body>
</html>
