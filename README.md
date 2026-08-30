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
├── secrets.config        # 管理者パスワード（リポジトリ管理外・手動作成）
├── secrets.config.sample # 上記のひな形
├── .gitignore            # data/ logs/ secrets.config などの誤コミット防止
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
├── secrets.config            ← 手順 5 で作成
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

### 5. 管理者パスワードの設定

`secrets.config.sample` を `secrets.config` にコピーし、後述の手順で生成した値を設定します。

```
copy secrets.config.sample secrets.config
```

> [!IMPORTANT]
> `secrets.config` を作成しない、または値が空のままだと **管理者削除機能は動作しません**
> （どのパスワードも受け付けない fail-closed 動作）。投稿・閲覧・本人削除は通常どおり動きます。
>
> `secrets.config` は `.gitignore` 済みです。**リポジトリにコミットしないでください。**

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

> [!IMPORTANT]
> **デフォルトパスワードは存在しません。** 管理者削除を使うには、以下の手順で
> `secrets.config` に値を設定する必要があります。未設定のままだと管理者削除は
> 常に拒否されます（fail-closed）。

### 保存形式

パスワードは **PBKDF2-HMAC-SHA1（ソルト付き・10万回反復）** で導出した値として、
リポジトリ管理外の `secrets.config` に保存します。ソースコードには一切埋め込みません。

```
<反復回数>$<ソルトBase64>$<ハッシュBase64>
```

| 項目 | 最小要件 |
|---|---|
| 反復回数 | 100,000 以上 |
| ソルト | 16 バイト以上のランダム値 |
| ハッシュ | 32 バイト以上 |

いずれかを満たさない値・書式不正の値は、設定ミスとみなして拒否されます。

### パスワードの設定・変更方法

**1. 値を生成する**（PowerShell / Windows Server 上でそのまま実行できます）

```powershell
$secure = Read-Host "管理者パスワードを入力" -AsSecureString
$plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
              [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

$iterations = 100000
$salt = New-Object byte[] 16
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)

$pbkdf2 = New-Object Security.Cryptography.Rfc2898DeriveBytes `
              -ArgumentList $plain, $salt, $iterations
$hash = $pbkdf2.GetBytes(32)

"{0}`${1}`${2}" -f $iterations,
                   [Convert]::ToBase64String($salt),
                   [Convert]::ToBase64String($hash)
```

出力例（`$` 区切りの 1 行）:

```
100000$Yk3v...==$9tQm...=
```

**2. `secrets.config` に貼り付ける**

```xml
<?xml version="1.0" encoding="utf-8"?>
<appSettings>
  <add key="AdminPassword" value="100000$Yk3v...==$9tQm...=" />
</appSettings>
```

保存すると ASP.NET がアプリを再起動し、次のリクエストから新しいパスワードが有効になります。
`default.aspx` の再ビルドや再配置は不要です。

> [!WARNING]
> 生成した値・元のパスワードを、`web.config` や `default.aspx`、コミットメッセージ、
> Issue などに書き込まないでください。`secrets.config` は `.gitignore` 済みですが、
> `git add -f` で強制追加しないよう注意してください。

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
- 管理者パスワードはソルト付き PBKDF2（10万回反復）で `secrets.config` に保持し、リポジトリには含めません。ただし全管理者で共有する単一パスワードであり、試行回数制限もありません。閉域網かつ Windows 認証済みユーザーのみが到達できる前提の簡易保護です。
- `data/` `logs/` および `secrets.config` は `.gitignore` 済みです。これらには社内ユーザー名・AD 表示名・伝言本文が含まれるため、リポジトリにコミットしないでください。
- `web.config` で `<deny users="?" />` を設定し、IIS 側の認証設定と二重に未認証アクセスを遮断しています。IIS で Windows 認証が有効になっていない場合は起動時に構成エラーとなります（フェイルクローズ）。
