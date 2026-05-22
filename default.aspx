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
                    //return user.DisplayName + "(" + username + ")";
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
            if (Array.IndexOf(new[] { "yellow", "blue", "red", "green" }, color) < 0) color = "yellow";

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

                // Compat: fall back to legacy "author" key if "author_id" is absent
                string authorId = noteObj.ContainsKey("author_id") ? noteObj["author_id"] : (noteObj.ContainsKey("author") ? noteObj["author"] : "");

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

        if (File.Exists(filePath))
        {
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                string content = File.ReadAllText(filePath);
                var noteObj = serializer.Deserialize<Dictionary<string, string>>(content);

                string authorId = noteObj.ContainsKey("author_id") ? noteObj["author_id"] : (noteObj.ContainsKey("author") ? noteObj["author"] : "");

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
    body { font-family: "Meiryo UI", sans-serif; background-color: #f4f7f6; margin: 0; color: #333; }
    header { background-color: #0056b3; color: white; padding: 15px 25px; display: flex; align-items: baseline; box-shadow: 0 2px 5px rgba(0,0,0,0.15); }
    .logo-main { font-size: 1.8rem; font-weight: bold; margin-right: 15px; }
    .logo-sub { font-size: 0.9rem; opacity: 0.85; border-left: 1px solid rgba(255,255,255,0.5); padding-left: 15px; }
    #board { padding: 25px; display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 25px; }
    .note { width: 100%; height: 250px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); padding: 15px; box-sizing: border-box; display: flex; flex-direction: column; transition: transform 0.2s; position: relative; border-radius: 2px; }
    .note:hover { transform: translateY(-3px); z-index: 10; box-shadow: 0 5px 15px rgba(0,0,0,0.2); }
    .note.yellow { background-color: #fffde7; border-top: 4px solid #fdd835; }
    .note.blue   { background-color: #e3f2fd; border-top: 4px solid #2196f3; }
    .note.red    { background-color: #ffebee; border-top: 4px solid #ef5350; }
    .note.green  { background-color: #e8f5e9; border-top: 4px solid #66bb6a; }
    .note-meta { display: flex; justify-content: space-between; font-size: 0.75rem; color: #888; margin-bottom: 8px; border-bottom: 1px dashed #ccc; padding-bottom: 4px; }
    .note-author { font-size: 0.8rem; color: #0056b3; text-align: right; margin-top: auto; font-weight: bold; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .note-title { font-weight: bold; font-size: 1.1rem; margin-bottom: 10px; overflow: hidden; max-height: 3em; line-height: 1.4; }
    .note-body { flex-grow: 1; font-size: 0.95rem; overflow-y: auto; line-height: 1.6; white-space: pre-wrap; word-break: break-all; margin-bottom: 5px; }
    .btn-delete-mine { position: absolute; top: 5px; right: 5px; width: 24px; height: 24px; line-height: 24px; text-align: center; color: #999; cursor: pointer; font-weight: bold; font-size: 16px; background: rgba(255,255,255,0.8); border-radius: 50%; }
    .btn-delete-mine:hover { background: #f44336; color: white; }
    #admin-mode-toggle { position: fixed; bottom: 10px; left: 10px; font-size: 0.8rem; color: #ccc; cursor: pointer; }
    #fab-add { position: fixed; bottom: 40px; right: 40px; width: 64px; height: 64px; background-color: #0056b3; color: white; border-radius: 50%; text-align: center; line-height: 60px; font-size: 32px; box-shadow: 0 4px 10px rgba(0,0,0,0.3); cursor: pointer; z-index: 100; user-select: none; }
    #fab-add:hover { background-color: #004494; transform: scale(1.1); }
    .modal-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0,0,0,0.6); z-index: 200; justify-content: center; align-items: center; }
    .modal-content { background-color: white; width: 90%; max-width: 500px; padding: 25px; border-radius: 8px; box-shadow: 0 10px 25px rgba(0,0,0,0.3); }
    .form-group { margin-bottom: 15px; }
    label { display: block; margin-bottom: 5px; font-weight: bold; font-size: 0.9rem;}
    input[type="text"], textarea, select, input[type="password"] { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; font-size: 1rem; }
    textarea { height: 120px; resize: vertical; font-family: inherit; }
    .btn-area { text-align: right; margin-top: 20px; }
    button { padding: 10px 20px; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; font-weight: bold; }
    .btn-cancel { background-color: #f0f0f0; color: #333; margin-right: 10px; }
    .btn-submit { background-color: #0056b3; color: white; }
    .btn-danger { background-color: #d32f2f; color: white; }
</style>
</head>
<body>

    <header>
        <div class="logo-main">ほわいとぼーど</div>
        <div class="logo-sub">伝言板</div>
    </header>

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
            <div class="form-group"><label>タイトル</label><input type="text" id="input-title" placeholder="例：クリスマス会参加のお知らせ"></div>
            <div class="form-group"><label>内容</label><textarea id="input-body" placeholder="内容を入力してください..."></textarea></div>
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
                <button class="btn-cancel" onclick="$('#modal-post').hide()">キャンセル</button>
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

<script>
    $(document).ready(function() {
        loadNotes();

        $('#fab-add').on('click', function() {
            $('#input-title').val(''); $('#input-body').val(''); $('#input-color').val('yellow');
            $('#modal-post').css('display', 'flex'); $('#input-title').focus();
        });

        $('#btn-save').on('click', function() {
            var title = $('#input-title').val(), body = $('#input-body').val(), color = $('#input-color').val();
            if(!title || !body) { alert('タイトルと内容は必須です。'); return; }
            var $btn = $(this); $btn.prop('disabled', true).text('保存中...');

            $.post('Default.aspx?action=save', { title: title, body: body, color: color }, function() {
                $('#modal-post').hide(); loadNotes();
            }).fail(function(xhr){
                alert('エラーが発生しました。\n' + xhr.responseText);
            }).always(function(){ $btn.prop('disabled', false).text('掲示'); });
        });

        $(document).on('click', '.btn-delete-mine', function() {
            var id = $(this).data('id');
            if(confirm('この内容を削除しますか？')) {
                $.post('Default.aspx?action=delete', { id: id }, function(res) {
                    var data = (typeof res === 'string') ? JSON.parse(res) : res;
                    if(data.status === 'success') { loadNotes(); }
                    else { alert(data.message); }
                });
            }
        });

        var adminMode = false;
        $('#admin-mode-toggle').on('click', function() {
            adminMode = !adminMode;
            if(adminMode) { alert('管理者削除モード：ON'); $('.note').css('cursor', 'crosshair'); }
            else { alert('管理者削除モード：OFF'); $('.note').css('cursor', 'default'); }
        });

        $(document).on('click', '.note', function() {
            if(!adminMode) return;
            var noteId = $(this).data('id');
            $('#admin-target-id').val(noteId);
            $('#admin-pass').val('');
            $('#modal-admin-delete').css('display', 'flex');
        });

        $('#btn-exec-admin-delete').on('click', function() {
            var id = $('#admin-target-id').val(), pass = $('#admin-pass').val();
            $.post('Default.aspx?action=delete', { id: id, admin_pass: pass }, function(res) {
                var data = (typeof res === 'string') ? JSON.parse(res) : res;
                if(data.status === 'success') { $('#modal-admin-delete').hide(); loadNotes(); }
                else { alert(data.message); }
            });
        });

        $('.modal-overlay').on('click', function(e) { if(e.target === this) $(this).hide(); });

        function loadNotes() {
            $.getJSON('Default.aspx?action=load', function(data) {
                var $board = $('#board'); $board.empty();
                if(data.length === 0) { $board.html('<p style="color:#777; margin:20px; text-align:center; width:100%;">現在、掲示されているものはありません。</p>'); return; }

                data.sort(function(a, b) { return (a.post_date < b.post_date) ? 1 : -1; });
                $.each(data, function(i, item) {
                    var deleteBtn = item.is_mine ? `<div class="btn-delete-mine" data-id="${item.id}" title="削除">×</div>` : '';
                    var html = `
                        <div class="note ${item.color}" data-id="${item.id}">
                            ${deleteBtn}
                            <div class="note-meta"><span>${item.post_date}</span><span>(～${item.expire_disp})</span></div>
                            <div class="note-title" title="${item.title}">${item.title}</div>
                            <div class="note-body">${item.body}</div>
                            <div class="note-author">by ${item.author_disp}</div>
                        </div>`;
                    $board.append(html);
                });
            });
        }
    });
</script>
</body>
</html>
