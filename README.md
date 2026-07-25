# 伝言板システム (Whiteboard)

社内閉域ネットワーク向けの、IIS + ASP.NET で動作するシンプルな付箋型伝言板です。  
Windows 認証（Active Directory）によりログインユーザーを自動識別し、ファイルベースで付箋データを管理します。

---

## 機能概要

- **付箋の投稿** : タイトル（50文字以内）・本文（400文字以内）・色（4色）を指定して付箋を掲示板に貼り付ける
- **自動削除** : 投稿から **7日後** に自動で期限切れ・削除される
- **本人削除** : 自分が投稿した付箋を削除ボタン（×）で削除できる
- **管理者削除** : 管理者パスワードで任意の付箋を強制削除できる
- **AD 表示名取得** : Active Directory の表示名（DisplayName）を投稿者名として表示する
- **ノーキャッシュ** : 常に最新データを取得するよう HTTP キャッシュを無効化
- **エラーログ** : サーバー側の例外を `logs/yyyyMM.log` に記録

### 付箋の色

| 色 | 用途の目安 |
|---|---|
| 黄色 | 一般 |
| 青色 | 通知・確認 |
| 赤色 | 重要・緊急 |
| 緑色 | イベント・その他 |

---

## システム要件

| 項目 | 要件 |
|---|---|
| Web サーバー | IIS 7.5 以上 |
| .NET Framework | 4.7 以上 |
| 認証方式 | Windows 認証（Active Directory ドメイン環境） |
| クライアント | モダンブラウザ（jQuery 3.6.0 使用） |

---

## ディレクトリ構成

```
whiteboard/
├── default.aspx          # アプリ本体（サーバーサイド C# + HTML/CSS/JS を一枚に集約）
├── web.config            # IIS・ASP.NET 設定ファイル
├── common/
│   └── jquery-3.6.0.min.js  # jQuery（別途配置が必要）
├── data/                 # 投稿データ格納フォルダ（実行時に自動生成）
│   ├── web.config            # 直接 HTTP アクセスを遮断する設定（自動生成）
│   └── yyyyMMdd_<GUID>.json  # 付箋データ（1投稿 = 1ファイル）
└── logs/                 # エラーログ格納フォルダ（実行時に自動生成）
    ├── web.config            # 直接 HTTP アクセスを遮断する設定（自動生成）
    └── yyyyMM.log            # 月次エラーログ
```

---

## セットアップ手順

### 1. ファイルの配置

IIS の仮想ディレクトリまたはサイトルートに以下を配置します。

```
whiteboard/
├── default.aspx
├── web.config
└── common/
    └── jquery-3.6.0.min.js   ← jQuery を別途入手して配置
```

> `data/` `logs/` フォルダはアプリが初回アクセス時に自動作成します。  
> IIS の実行アカウント（アプリプールのユーザー）に、アプリのルートフォルダへの **書き込み権限** が必要です
> （`data/` `logs/` の自動生成に使用します）。

> [!WARNING]
> **`default.aspx` は配置前に Shift-JIS へ変換してください。**  
> 本リポジトリのファイルは UTF-8 で管理していますが、IIS（ASP.NET）は ASPX ファイルを
> Shift-JIS（CP932）として解釈するため、UTF-8 のまま配置するとコンパイルエラーが発生します。
>
> 変換例（PowerShell）:
> ```powershell
> $content = [System.IO.File]::ReadAllText("default.aspx", [System.Text.Encoding]::UTF8)
> [System.IO.File]::WriteAllText("default.aspx", $content, [System.Text.Encoding]::GetEncoding("shift_jis"))
> ```
>
> 変換例（iconv / Linux・Mac）:
> ```bash
> iconv -f UTF-8 -t SHIFT_JIS default.aspx > default_sjis.aspx
> ```

### 2. IIS の認証設定

IIS マネージャーで対象サイト／アプリに対して以下を設定します。

- **Windows 認証** : 有効
- **匿名認証** : 無効

### 3. .NET バージョンの確認

`web.config` の `targetFramework` をサーバーの .NET バージョンに合わせます（デフォルト: `4.7`）。

```xml
<compilation debug="false" targetFramework="4.7">
```

### 4. jQuery の配置

[jQuery 公式サイト](https://jquery.com/) または社内ミラーから `jquery-3.6.0.min.js` を入手し、  
`common/` フォルダに配置してください。

---

## データ仕様

付箋データは `data/` フォルダに JSON ファイルとして 1 投稿 1 ファイルで保存されます。

### ファイル名形式

```
yyyyMMdd_<GUID>.json
```

ファイル名の先頭 8 桁が **有効期限（年月日）** です。  
ページ読み込み時に期限切れファイルは自動的に削除されます。

### JSON スキーマ

```json
{
  "id": "20251231_xxxx-xxxx-xxxx.json",
  "title": "タイトル（HTMLエンコード済み）",
  "body": "本文（HTMLエンコード済み・改行は<br>変換済み）",
  "color": "yellow | blue | red | green",
  "author_id": "DOMAIN\\username",
  "author_name": "AD表示名",
  "post_date": "yyyy/MM/dd HH:mm",
  "expire_disp": "MM/dd"
}
```

---

## API エンドポイント

すべて `default.aspx` に対するリクエストで処理します。

| action | メソッド | 説明 |
|---|---|---|
| `save` | POST | 付箋を投稿する |
| `load` | GET | 付箋一覧を取得する（期限切れを同時に削除） |
| `delete` | POST | 付箋を削除する（本人 or 管理者） |

### リクエスト要件

CSRF 対策として、`action` 付きのリクエストには `X-Requested-With: XMLHttpRequest`
ヘッダーが必要です（jQuery の Ajax は同一オリジンで自動付与します）。
ヘッダーのないリクエストは `400` を返します。

### レスポンス

`load` は付箋の配列を返します。`save` / `delete` は下記の形式を返します。

```json
{ "status": "success" }
{ "status": "error", "message": "権限がありません。" }
```

エラー時は内容に応じた HTTP ステータス（`400` / `403` / `404` / `500`）を併せて返します。
クライアントは HTTP ステータスと `status` の両方を判定します。

---

## 管理者パスワード

管理者削除機能は、画面左下の **Admin** リンクをクリックして管理者モードに切り替えると使用できます。  
任意の付箋をクリックするとパスワード入力ダイアログが表示されます。

### デフォルトパスワード

```
admin9999
```

### パスワードの変更方法

`default.aspx` 冒頭の以下の定数を、新しいパスワードの **SHA-256 ハッシュ値**（小文字16進数）に置き換えます。

```csharp
private const string MASTER_PASS_HASH = "240be518fabd2724ddb6f04eebdd92bd6073057426a7013d8519520743b08272";
```

SHA-256 ハッシュの生成例（PowerShell）:

```powershell
$pass = "新しいパスワード"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pass)
$hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
($hash | ForEach-Object { $_.ToString("x2") }) -join ""
```

---

## 注意事項

- **`default.aspx` は IIS 配置前に Shift-JIS へ変換すること。** リポジトリは UTF-8 で管理しているが、IIS（ASP.NET）は Shift-JIS を要求するためコンパイルエラーになる（「セットアップ手順 1」参照）。
- `web.config` の `debug` は既定で `false`（本番向け）です。開発・検証時のみ `true` に変更してください。
- `customErrors mode` は既定で `RemoteOnly`（サーバー上のブラウザからのみエラー詳細を表示）です。
- `default.aspx` は `ValidateRequest="false"`（+ `web.config` の `requestValidationMode="2.0"`）で動作します。
  「10<20」のように `<` を含む投稿を ASP.NET の要求検証エラーにしないための設定で、
  投稿値はサーバー側で必ず HtmlEncode してから保存・出力しています。
- 本システムは閉域ネットワーク内での利用を想定しています。インターネット公開環境での使用は想定外です。
- 投稿内容は HtmlEncode によりエスケープされますが、管理・運用ルールの整備も合わせて実施してください。
- 管理者パスワードはソルトなしの SHA-256 ハッシュで保持しています。閉域網の簡易保護であり、強度の高い認証機構ではありません。
