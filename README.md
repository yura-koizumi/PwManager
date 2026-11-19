# PwManager 運用ガイド

Windows 10/11 の標準機能（Windows PowerShell 5.1 と Windows Forms）と、Microsoft 製の
`Microsoft.PowerShell.SecretManagement` / `Microsoft.PowerShell.SecretStore` だけで動くパスワード管理ツールです。
クラウドに送信せず、費用もかかりません。

---

## 1. セットアップ（初回・アップデート共通）

1. このフォルダー（`PwManager`）を PC の任意の場所に置きます。
2. フォルダー内で Shift + 右クリック →「PowerShell ウィンドウをここで開く」を選び、次を実行します。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
   ```

3. 初回だけ、マスターパスワードの設定を求められます。
   - 12 文字以上で、ほかでは使っていないもの（長めのフレーズがおすすめ）
   - **忘れると、保存したパスワードは二度と取り出せません。** 紙に書いて施錠できる場所に保管するなど、社内ルールに沿って保管してください。
4. デスクトップとスタートメニューに「PwManager」ができます。

最初の導入時だけ、PowerShell Gallery（インターネット）からモジュールをダウンロードします。それ以降の利用はすべて PC の中で完結します。

> **アップデートするとき**：新しい `PwManager` フォルダーで同じ `Install.ps1` を実行します。設定と保管庫のデータは別の場所にあるため、そのまま残ります。

### 最初にやっておくこと：バックアップ先の設定

画面の「設定」（または PowerShell で `Edit-PwConfig`）を開き、`BackupFolder` を指定して保存します。

```json
"BackupFolder": "D:\\Backup\\PwManager",
```

パスの `\` は `\\` と2つ重ねて書きます。指定しておくと、起動したときに前回から 7 日以上経っていれば、自動でバックアップします。

---

## 2. 毎日の使い方

デスクトップの「PwManager」を起動し、マスターパスワードを入力します。

| やりたいこと | 操作 |
| --- | --- |
| 探す | 上の検索欄に入力します（スペースで区切ると AND 検索） |
| **パスワードをコピー** | 行を選んで **Enter**。検索欄で Enter を押すと、先頭の行のパスワードをコピーします |
| ID / メール / URL をコピー | 各ボタン、その列をダブルクリック、または **Ctrl+C**（選んでいるセルの列）|
| URL をブラウザーで開く | 「URLを開く」ボタン、または右クリック |
| 新規登録 | **Ctrl+N**。「生成」を押すと強いパスワードを自動で作ります |
| 編集 | **F2**、またはタイトルをダブルクリック。パスワード欄を空欄のままにすると、パスワードは変わりません |
| 削除 | **Del**（確認画面が出ます） |
| 席を離れる | **Ctrl+L** でロック（10 分間操作がないと自動でロック） |

**コピーしたパスワードの扱い**

- コピーしたパスワードは 30 秒後に自動で消えます。ただし、その間に別の物をコピーした場合は、そちらを消さないようにしています。
- Windows のクリップボード履歴（Win+V）やクラウド同期には残りません。

---

## 3. 設定のカスタマイズ

設定ファイルは `%APPDATA%\PwManager\config.json` です。画面の「設定」から開き、保存したあと PwManager を開き直すと反映されます。
書かなかった項目には既定値が使われるので、変えたい項目だけを書けば十分です。

| 項目 | 既定値 | 内容 |
| --- | --- | --- |
| `ClipboardClearSeconds` | 30 | コピーしたパスワードを消すまでの秒数（0 にすると消さない） |
| `ExcludeFromClipboardHistory` | true | パスワードをクリップボード履歴やクラウド同期の対象から外す |
| `AutoLockMinutes` | 10 | 何分間操作がなければロックするか（0 にすると自動ロックしない） |
| `UnlockTimeoutSeconds` | 3600 | 一度ロックを解除したあと、再入力なしで使える秒数 |
| `Fields` | ID, メール, URL, カテゴリ, 備考 | 表示・入力する項目（下で詳しく説明） |
| `Categories` | 仕事 ほか | カテゴリの候補。自分で入力した値も候補に加わります |
| `PasswordGenerator` | 20 文字・記号あり | 「生成」で作るパスワードの長さと、使う記号 |
| `BackupFolder` | （空） | バックアップの保存先。USB メモリーや社内の個人フォルダーなど |
| `BackupKeep` | 30 | 残しておくバックアップの数 |
| `BackupIntervalDays` | 7 | この日数が経つと、起動時に自動でバックアップする |

### 項目（Fields）を追加・変更する

例：「社員番号」の項目を追加し、その値もコピーできるようにする場合

```json
"Fields": [
  { "Name": "Id",       "Label": "ID",       "Copy": true },
  { "Name": "EmpNo",    "Label": "社員番号", "Copy": true },
  { "Name": "Email",    "Label": "メール",   "Copy": true },
  { "Name": "Url",      "Label": "URL",      "Copy": true, "Open": true },
  { "Name": "Category", "Label": "カテゴリ", "Type": "Category" },
  { "Name": "Note",     "Label": "備考",     "Multiline": true }
]
```

| キー | 意味 |
| --- | --- |
| `Name` | 保存に使う名前（英数字）。**一度使い始めたら変えないでください**（変えると、それまでに入れた値が表示されなくなります） |
| `Label` | 画面に表示する名前。いつでも自由に変えられます |
| `Copy` | 「〇〇をコピー」ボタンと右クリックメニューに出す |
| `Open` | 「〇〇を開く」ボタンを出す（http:// または https:// で始まる値だけ開きます） |
| `Sensitive` | コピーした値をパスワードと同じように扱う（一定時間で消し、履歴にも残さない） |
| `Type: "Category"` | カテゴリとして扱い、絞り込み用のリストに使う |
| `Multiline` | 複数行で入力できるようにする |

項目を `Fields` から削除しても、保存済みのデータは消えません。あとで戻せば、また表示されます。

---

## 4. バックアップ・復元・PC の移行

### バックアップ

画面の「バックアップ」ボタン、または PowerShell で次を実行します。

```powershell
Backup-PwVault                          # BackupFolder に保存
Backup-PwVault -Destination E:\Backup   # 保存先を指定する
```

ZIP の中の保管庫データはマスターパスワードで暗号化されたままですが、念のため共有フォルダーなどには置かないでください。

古いバックアップは `BackupKeep` の数を超えた分だけ自動で削除します。数えるのはこの PC のバックアップ（ファイル名に PC 名が入っています）だけなので、USB メモリーなどを複数の PC で共用しても、ほかの PC のバックアップは消しません。

### 復元・新しい PC への移行

1. （新しい PC の場合）このフォルダーをコピーして `Install.ps1` を実行します。マスターパスワードを求められたら、仮のものを入力して構いません（復元すると上書きされます）。
2. PwManager の画面を閉じ、**新しく開いた** PowerShell で次を実行します（画面が開いていると、復元は止まります）。

   ```powershell
   Restore-PwVault -Path D:\Backup\PwManager\PwManager-backup-PC01-20261118-090000.zip -IncludeConfig
   ```

3. PwManager を起動し、**バックアップを取ったときのマスターパスワード**で開きます。

復元する前の保管庫は `%APPDATA%\PwManager\pre-restore-*.zip` に自動で退避されます。

> **年に 1 回は、別の PC か別のユーザーで復元を試してください。** バックアップは「元に戻せること」を確かめて初めて役に立ちます。

---

## 5. Excel からの移行

1. Excel の 1 行目（見出し）を `Title`, `Password`, `Id`, `Email`, `Url`, `Category`, `Note` にします。日本語の見出し（タイトル、パスワード、および `Fields` の `Label`）でも構いません。
2. 「名前を付けて保存」で **CSV UTF-8** を選んで保存します。
3. PowerShell で次を実行します。

   ```powershell
   Import-PwCsv -Path C:\work\passwords.csv
   # Excel の「CSV (コンマ区切り)」で保存した場合
   Import-PwCsv -Path C:\work\passwords.csv -Encoding Default
   ```

4. **取り込みが済んだら、CSV と元の Excel ファイルを削除し、ごみ箱も空にしてください。**

同じ CSV を 2 回取り込むと、エントリが重複します。

将来、会社が公式のパスワード管理ツールを導入した場合などに備えて、CSV に書き出すこともできます。
`Export-PwCsv -Path out.csv -IncludePassword` を実行すると、パスワードを平文で含めて書き出します（確認画面が出ます）。

Excel で開いたときに数式として実行されないよう、`=` `+` `-` `@` で始まるタイトルや項目の値には、先頭に `'` を付けて書き出します（`Import-PwCsv` で取り込むと元に戻ります）。パスワードは書き換えません。

---

## 6. PowerShell から使う

| コマンド | 内容 |
| --- | --- |
| `pwm` | 画面を開く |
| `Get-PwEntry ポータル` | 一覧を検索する（パスワードは表示しない） |
| `Copy-PwField ポータル` | パスワードをコピーする |
| `Copy-PwField ポータル Id` | ID をコピーする |
| `New-PwPassword -Length 24` | パスワードを生成する |
| `Edit-PwConfig` | 設定ファイルを開く |
| `Backup-PwVault` / `Restore-PwVault` | バックアップ・復元 |
| `Import-PwCsv` / `Export-PwCsv` | CSV の取り込み・書き出し |

---

## 7. セキュリティ上の注意

- パスワードは SecretStore によって暗号化して保存されます。開くにはマスターパスワードが必要です。
- **秘密にすべき内容はパスワード欄に入れてください。** SecretManagement の仕様上、ID・URL・備考などのメタデータは、機密情報を入れることを前提にしていません。PIN や秘密の質問の答えなどは、備考に書かずに別のエントリとして登録してください。
- 追加・更新・削除・バックアップの記録が `%APPDATA%\PwManager\audit.log` に残ります（パスワードそのものは記録しません）。1 MB（約 1 万件）を超えると `audit.old.log` に移し、その 1 つ前の記録は消えます。
- 画面のロック（Ctrl+L・自動ロック）は、画面の表示を消して、再開時にマスターパスワードを確かめるものです。保管庫そのものは `UnlockTimeoutSeconds` の間、PwManager のプロセスの中で開いたままです。席を離れるときは Windows のロック（**Win+L**）も併用してください。
- 会社の規程で、業務用パスワードの保管方法が定められている場合は、それに従ってください。

---

## 8. 困ったときは

| 症状 | 対処 |
| --- | --- |
| ショートカットから起動しない | PowerShell で `pwm` を実行すると、エラーの内容が表示されます |
| 「設定ファイルの書式が正しくありません」と表示される | `config.json` の `,` や `"` の過不足を確認します。分からなくなったら、ファイルを削除すれば既定値に戻ります |
| マスターパスワードを忘れた | 復元する方法はありません。`Reset-SecretStore` で初期化できますが、**データはすべて消えます** |
| 「スクリプトの実行が無効」と表示される | 会社のポリシーで制限されている可能性があります。情報システム担当に相談してください |
| 文字化けする | `.ps1` や `.psm1` を編集したときは、**UTF-8（BOM 付き）** で保存してください |

---

## 9. ファイルの構成（保守する人向け）

```text
PwManager\                 … 配布用フォルダー
  Install.ps1              … セットアップ・アップデート
  README.md
  tests\                   … 自動テスト（配布・インストールの対象外）
  PwManager\               … 本体（Documents\WindowsPowerShell\Modules\PwManager にコピーされる）
    PwManager.psd1         … バージョン情報（更新するときは ModuleVersion を上げる）
    PwManager.psm1         … 保管庫の操作、バックアップ、CSV、コマンド
    Gui.ps1                … 画面
    Launch.ps1             … ショートカットから呼び出される起動スクリプト
    config.default.json    … 設定の既定値

%APPDATA%\PwManager\       … config.json / state.json / audit.log / audit.old.log / pre-restore-*.zip
%LOCALAPPDATA%\Microsoft\PowerShell\secretmanagement\localstore\  … 暗号化された保管庫（SecretStore が管理）
```

### 修正するときの手順

1. 修正したら、テストを実行します（追加のモジュールは不要で、実際の保管庫やデータには触れません）。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
   ```

   クリップボードのテストは、実行中にクリップボードを書き換えます（終わると元のテキストに戻します）。
2. `PwManager.psd1` の `ModuleVersion` を上げ、git にコミットします。
3. 利用者は、新しいフォルダーで `Install.ps1` を実行すれば更新されます。

SecretManagement / SecretStore は、`Install.ps1` でメジャーバージョン 1 系に固定しています。2.0 以降が出たら、テストと実際の画面で動作を確かめてから、`Install.ps1` の `-MaximumVersion` を上げてください。

**保存形式（スキーマ v1）**

- シークレットの名前は `pwm:<GUID>` です。こうしておくと、タイトルを変えてもデータは同じまま残り、同じサービスで複数のアカウントを登録することもできます。
- シークレットの本体はパスワード（SecureString）です。
- メタデータには、`Title`、`Created`、`Updated`、`Schema`、そして `Fields` で定義した各項目が入ります。
- 名前が `pwm:` で始まらないシークレットは、このツールでは表示しません。ほかの用途のシークレットと同じ保管庫に共存できます。
