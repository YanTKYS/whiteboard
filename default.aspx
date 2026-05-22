<%@ Page Language="C#" Debug="true" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Security.Cryptography" %>
<%@ Import Namespace="System.Text" %>
<%-- AD操作用のライブラリを参照 --%>
<%@ Import Namespace="System.DirectoryServices.AccountManagement" %>

<script runat="server">
    // ==========================================
    // サーバーサイド処理 (C#)
    // ==========================================
    
    private string DataFolderPath { get { return Server.MapPath("./data/"); } }
    
    // 管理者パスワード(ハッシュ値): admin9999
    private const string MASTER_PASS_HASH = "240be518fabd2724ddb6f04eebdd92bd6073057426a7013d8519520743b08272"; 

    protected void Page_Load(object sender, EventArgs e)
    {
        Response.Cache.SetCacheability(HttpCacheability.NoCache);

        // Windows認証チェック
        if (!User.Identity.IsAuthenticated)
        {
            Response.StatusCode = 401;
            Response.Write("Windows認証が無効です。IISの設定を確認してください。");
            Response.End();
            return;
        }

        string action = Request["action"];
        
        if (action == "save") SaveNote();
        else if (action == "load") GetNotesAndCleanup();
        else if (action == "delete") DeleteNote();
    }

    // ADから表示名を取得する関数
    private string GetAdDisplayName(string domainUser)
    {
        try
        {
            // domain\user を分割
            string[] parts = domainUser.Split('\\');
            if (parts.Length != 2) return domainUser; // 形式が違う場合はそのまま返す

            string domain = parts[0];
            string username = parts[1];

            // ADコンテキストを作成（現在のドメイン）
            using (PrincipalContext ctx = new PrincipalContext(ContextType.Domain))
            {
                // ユーザーを検索
                UserPrincipal user = UserPrincipal.FindByIdentity(ctx, username);
                if (user != null)
                {
                    // 表示名があれば「田中太郎(taro)」形式にして返す
                    if (!string.IsNullOrEmpty(user.DisplayName))
                    {
                        //return user.DisplayName + "(" + username + ")";
                        return user.DisplayName;
                    }
                }
            }
        }
        catch 
        {
            // AD接続エラー等の場合は、IDをそのまま返す
        }
        return domainUser; // 取得できなかった場合は元のIDを返す
    }

    // SHA256ハッシュ
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

    // 1. ノートの保存処理
    private void SaveNote()
    {
        try
        {
            string title = Request["title"];
            string body = Request["body"];
            string color = Request["color"];
            
            // システム上のID (例: DOMAIN\taro)
            string currentUserId = User.Identity.Name;
            
            // ADから表示名を取得 (例: 田中太郎(taro))
            string displayName = GetAdDisplayName(currentUserId);

            if (string.IsNullOrEmpty(title) || string.IsNullOrEmpty(body)) return;

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
                author_id = currentUserId, // 削除判定用（厳密なID）
                author_name = displayName, // 表示用（AD表示名）
                post_date = DateTime.Now.ToString("yyyy/MM/dd HH:mm"),
                expire_disp = expireDate.ToString("MM/dd")
            };

            JavaScriptSerializer serializer = new JavaScriptSerializer();
            string jsonContent = serializer.Serialize(noteData);
            
            if (!Directory.Exists(DataFolderPath)) Directory.CreateDirectory(DataFolderPath);
            File.WriteAllText(Path.Combine(DataFolderPath, fileName), jsonContent);

            Response.ContentType = "application/json";
            Response.Write("{\"status\":\"success\"}");
        }
        catch (Exception ex)
        {
            Response.StatusCode = 500;
            Response.Write("{\"status\":\"error\", \"message\":\"" + ex.Message + "\"}");
        }
        Response.End();
    }

    // 2. ノート取得
    private void GetNotesAndCleanup()
    {
        List<object> notes = new List<object>();
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        string currentUserId = User.Identity.Name; 
        
        if (!Directory.Exists(DataFolderPath)) Directory.CreateDirectory(DataFolderPath);

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
                
                // 互換性維持: 古いデータなどで author_id がない場合は author を見る
                string authorId = noteObj.ContainsKey("author_id") ? noteObj["author_id"] : (noteObj.ContainsKey("author") ? noteObj["author"] : "");
                
                // 表示名: author_name があればそれを使う。なければID
                string authorName = noteObj.ContainsKey("author_name") ? noteObj["author_name"] : authorId;
                // ドメイン名(DOMAIN\)が残っていたら削る（見栄え調整）
                authorName = authorName.Replace(authorId.Split('\\')[0] + "\\", ""); 

                // 自分かどうか判定
                bool isMine = authorId.Equals(currentUserId, StringComparison.OrdinalIgnoreCase);
                
                var responseObj = new {
                    id = noteObj["id"],
                    title = noteObj["title"],
                    body = noteObj["body"],
                    color = noteObj["color"],
                    post_date = noteObj["post_date"],
                    expire_disp = noteObj["expire_disp"],
                    author_disp = authorName, // 整形済みの名前
                    is_mine = isMine 
                };
                
                notes.Add(responseObj);
            }
            catch { }
        }

        Response.ContentType = "application/json";
        Response.Write(serializer.Serialize(notes));
        Response.End();
    }

    // 3. 削除処理
    private void DeleteNote()
    {
        string targetId = Request["id"];
        string adminPass = Request["admin_pass"]; 
        string currentUserId = User.Identity.Name;

        string filePath = Path.Combine(DataFolderPath, targetId);

        if (File.Exists(filePath))
        {
            try 
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                string content = File.ReadAllText(filePath);
                var noteObj = serializer.Deserialize<Dictionary<string, string>>(content);
                
                string authorId = noteObj.ContainsKey("author_id") ? noteObj["author_id"] : (noteObj.ContainsKey("author") ? noteObj["author"] : "");

                // 本人確認 (ID同士で比較)
                bool isMine = authorId.Equals(currentUserId, StringComparison.OrdinalIgnoreCase);

                // 管理者パスワード確認
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
            catch
            {
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
    /* CSSは前回と同じ */
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
    .note-author { font-size: 0.8rem; color: #0056b3; text-align: right; margin-top: auto; font-weight: bold; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; } /* 名前が長い場合の対策 */
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
    <div id="fab-add" title="メモを貼る">＋</div>
    <div id="admin-mode-toggle" title="管理者削除">Admin</div>

    <div id="modal-post" class="modal-overlay">
        <div class="modal-content">
            <h3 style="margin-top:0;">新規貼り付け</h3>
            <p style="font-size:0.85rem; color:#d32f2f; background:#ffebee; padding:5px; border-radius:4px;">
                ※あなたの氏名で投稿されます。<br>
                ※投稿は7日後に自動的に削除されます。
            </p>
            <div class="form-group"><label>件名</label><input type="text" id="input-title" placeholder="例：年末調整書類の提出について"></div>
            <div class="form-group"><label>内容</label><textarea id="input-body" placeholder="内容を入力してください..."></textarea></div>
            <div class="form-group">
                <label>付箋の色</label>
                <select id="input-color">
                    <option value="yellow">黄色（一般）</option>
                    <option value="blue">青色（通知・周知）</option>
                    <option value="red">赤色（重要・緊急）</option>
                    <option value="green">緑色（イベント・その他）</option>
                </select>
            </div>
            <div class="btn-area">
                <button class="btn-cancel" onclick="$('#modal-post').hide()">キャンセル</button>
                <button class="btn-submit" id="btn-save">貼る</button>
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
            if(!title || !body) { alert('件名と内容は必須です。'); return; }
            var $btn = $(this); $btn.prop('disabled', true).text('保存中...');
            
            $.post('Default.aspx?action=save', { title: title, body: body, color: color }, function() {
                $('#modal-post').hide(); loadNotes();
            }).fail(function(xhr){
                alert('エラーが発生しました。\n' + xhr.responseText);
            }).always(function(){ $btn.prop('disabled', false).text('貼る'); });
        });

        $(document).on('click', '.btn-delete-mine', function() {
            var id = $(this).data('id');
            if(confirm('この投稿を削除しますか？')) {
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
                if(data.length === 0) { $board.html('<p style="color:#777; margin:20px; text-align:center; width:100%;">現在、掲示されている情報はありません。</p>'); return; }
                
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