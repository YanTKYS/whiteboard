# 伝言板システム (Whiteboard)

社内閉域ネットワーク向けの、IIS + ASP.NET で動作するシンプルな付箋型伝言板です。  
Windows 認証（Active Directory）によりログインユーザーを自動識別し、ファイルベースで付箋データを管理します。

---

## 機能概要

- **付箋の投稿** : タイトル（50文字以内）・本文（400文字以内）・色（4色）を指定して付箋を掲示板に貼り付ける
- **自動削除** : 投稿から **7日後** に自動で期限切れ・削除される
- **本人削除** : 自分が投稿した付箋を削除ボタン（×）で削除できる
- **管理者削除** : 特定の AD グループのメンバーが任意の付箋を強制削除できる
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
├── local.config          # 環境固有設定：管理者ADグループ名（リポジトリ管理外・手動作成）
├── local.config.sample   # 上記のひな形
├── .gitignore            # data/ logs/ local.config などの誤コミット防止
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
├── local.config              ← 手順 5 で作成
└── common/
    └── jquery-3.6.0.min.js   ← jQuery を別途入手して配置
```

> `data/` `logs/` フォルダはアプリが初回アクセス時に自動作成します。  
> IIS の実行アカウント（アプリプールのユーザー）に、アプリのルートフォルダへの **書き込み権限** が必要です
> （`data/` `logs/` の自動生成に使用します）。

> [!NOTE]
> **ファイルは UTF-8 のまま配置してください。文字コードの変換は不要です。**  
> `web.config` の `<globalization fileEncoding="utf-8" />` で ASPX の文字コードを
> 明示しているため、リポジトリのファイルをそのままコピーするだけで動作します。
>
> この指定がないと、ASP.NET はサーバーの既定コードページ（日本語 Windows では
> Shift-JIS）で解釈するため、文字化けやコンパイルエラーが発生します。
>
> 以前のバージョンで `default.aspx` を Shift-JIS に変換して配置していた場合は、
> **`default.aspx` と `web.config` を必ずセットで差し替えてください。**

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

### 5. 管理者グループの設定

Active Directory に管理者用のセキュリティグループ（例: `Whiteboard-Admins`）を作成し、
強制削除を許可するユーザーを所属させます。

続いて `local.config.sample` を `local.config` にコピーし、そのグループの
**sAMAccountName**（ドメイン接頭辞なし）を設定します。

```
copy local.config.sample local.config
```

```xml
<appSettings>
  <add key="AdminGroup" value="Whiteboard-Admins" />
</appSettings>
```

> [!IMPORTANT]
> `local.config` を作成しない、値が空、または存在しないグループ名を指定した場合、
> **管理者削除は誰にも許可されません**（fail-closed）。
> 投稿・閲覧・本人削除は通常どおり動きます。
>
> `local.config` は `.gitignore` 済みです。社内の AD グループ名を公開リポジトリに
> 含めないための分離なので、**コミットしないでください。**

---

## データ仕様

付箋データは `data/` フォルダに JSON ファイルとして 1 投稿 1 ファイルで保存されます。

### ファイル名形式

```
yyyyMMdd_<GUID>.json
```

ファイル名の先頭 8 桁が **有効期限（年月日）** です。  
ページ読み込み時に期限切れファイルは自動的に削除されます。

> [!NOTE]
> **投稿内容は平文で保存されます。** HTML エスケープは保存時ではなく描画時に、
> 描画先のコンテキストに応じて行います（テキストノード／属性値）。
> これにより、`data/` の JSON を直接編集・改竄しても、その内容が
> HTML として解釈されることはありません。

### JSON スキーマ

```json
{
  "id": "20251231_xxxx-xxxx-xxxx.json",
  "title": "タイトル（平文）",
  "body": "本文（平文・改行は \\n のまま）",
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

## 管理者権限（強制削除）

任意の付箋を強制削除できるのは、`local.config` の `AdminGroup` で指定した
**AD グループのメンバーだけ**です。共有パスワードは使用しません。

### 判定の仕組み

Windows 認証で識別済みのログインユーザーについて、`UserPrincipal.IsMemberOf()` で
グループ所属を AD に問い合わせます。

- **削除リクエストのたびに AD へ問い合わせます。** グループから外した時点で権限は即座に失効します
- グループ名未設定・グループが存在しない・AD に到達できない場合は、**すべて拒否**します（fail-closed）。AD 障害時に権限が開くことはありません
- 画面左下の **Admin** リンクは、管理者にのみ表示されます。ただしこれは表示上の制御であり、権限判定はサーバー側で行います（描画時の判定結果のみ 5 分間キャッシュしますが、削除時は必ず再問い合わせします）

### 権限の付与・剥奪

AD グループのメンバーを増減させるだけです。`default.aspx` や `local.config` の
編集、アプリの再起動・再配置は不要です。

### 使い方

1. 画面左下の **Admin** リンクをクリックして管理者削除モードに切り替える（ヘッダーが赤くなります）
2. 削除したい付箋をクリックし、確認ダイアログで OK を選択する

> [!NOTE]
> **入れ子グループについて。** `IsMemberOf()` は直接所属を判定します。
> 管理者グループに別のグループを入れ子で含めた場合、その配下のユーザーは
> 管理者として認識されない可能性があります。
> **管理者ユーザーは `AdminGroup` に直接所属させてください。**

---

## 注意事項

- **ファイルは UTF-8 のまま配置すること。** `web.config` の `<globalization fileEncoding="utf-8" />` で ASPX の文字コードを明示しているため、変換は不要（「セットアップ手順 1」参照）。
- `web.config` の `debug` は既定で `false`（本番向け）です。開発・検証時のみ `true` に変更してください。
- `customErrors mode` は既定で `RemoteOnly`（サーバー上のブラウザからのみエラー詳細を表示）です。
- `default.aspx` は `ValidateRequest="false"`（+ `web.config` の `requestValidationMode="2.0"`）で動作します。
  「10<20」のように `<` を含む投稿を ASP.NET の要求検証エラーにしないための設定です。
  投稿値は平文で保存し、描画時にコンテキストに応じてエスケープします。
- 本システムは閉域ネットワーク内での利用を想定しています。インターネット公開環境での使用は想定外です。
- 投稿内容は描画時にエスケープされますが、管理・運用ルールの整備も合わせて実施してください。
- レスポンスに以下のセキュリティヘッダーを付与しています。
  - `Content-Security-Policy` : `default-src 'none'` を基点に、自サイトのスクリプトとリクエスト毎の nonce を持つインラインブロックのみ実行を許可します。万一エスケープを迂回されても、注入されたスクリプトは実行されません
  - `X-Frame-Options: DENY` : 削除操作を狙ったクリックジャッキングを防ぎます（CSP の `frame-ancestors 'none'` の後方互換）
  - `X-Content-Type-Options: nosniff` / `Referrer-Policy: no-referrer`
- 管理者判定は AD グループの所属で行います。共有パスワードを持たないため、パスワードの漏洩・使い回し・総当たりという経路自体が存在しません。権限の管理は AD 側の運用に一本化されます。
- `data/` `logs/` および `local.config` は `.gitignore` 済みです。これらには社内ユーザー名・AD 表示名・伝言本文・AD グループ名が含まれるため、リポジトリにコミットしないでください。
- `web.config` で `<deny users="?" />` を設定し、IIS 側の認証設定と二重に未認証アクセスを遮断しています。IIS で Windows 認証が有効になっていない場合は起動時に構成エラーとなります（フェイルクローズ）。
