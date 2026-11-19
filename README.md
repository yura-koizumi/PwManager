# PwManager 運用ガイド

Windows 10/11 の標準機能（Windows PowerShell 5.1 と Windows Forms）と、Microsoft 製の
`Microsoft.PowerShell.SecretManagement` / `Microsoft.PowerShell.SecretStore` だけで動くパスワード管理ツールです。
クラウドに送信せず、費用もかかりません。

---

## 1. セットアップ（初回・アップデート共通）

1. このフォルダー（`PwManager`）を PC の任意の場所に置きます。
2. フォルダー内の `Install.bat` をダブルクリックします。

   PowerShell から実行する場合は、フォルダー内で Shift + 右クリック →「PowerShell ウィンドウをここで開く」を選び、次を実行します。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
   ```

3. 初回だけ、マスターパスワードの設定を求められます。
   - 12 文字以上で、ほかでは使っていないもの（長めのフレーズがおすすめ）
   - **忘れると、保存したパスワードは二度と取り出せません。** 紙に書いて施錠できる場所に保管するなど、社内ルールに沿って保管してください。
4. デスクトップとスタートメニューに「PwManager」ができます。

最初の導入時だけ、PowerShell Gallery（インターネット）からモジュールをダウンロードします。それ以降の利用はすべて PC の中で完結します。

> **アップデートするとき**：新しい `PwManager` フォルダーで同じ `Install.bat`（または `Install.ps1`）を実行します。設定と保管庫のデータは別の場所にあるため、そのまま残ります。

---

## 2. 毎日の使い方

デスクトップの「PwManager」を起動し、マスターパスワードを入力します。画面のボタンは「＋ 新規」と「≡（メニュー）」だけで、行ごとの操作はキーボード・ダブルクリック・右クリックで行います。

| やりたいこと | 操作 |
| --- | --- |
| 探す | 上の検索欄に入力します（スペースで区切ると AND 検索。大文字小文字・全角半角・ひらがなカタカナは区別しません） |
| 並べ替える | 列の見出しをクリック（もう一度クリックすると逆順） |
| **パスワードをコピー** | 行を選んで **Enter**。検索欄で Enter を押すと、選ばれている行（検索した直後は先頭の行）のパスワードをコピーします |
| ID / URL をコピー | その列をダブルクリック、**Ctrl+C**（選んでいるセルの列）、または右クリック |
| URL をブラウザーで開く | 右クリック →「URLを開く」 |
| 新規登録 | 「＋ 新規」または **Ctrl+N**。「生成」を押すと強いパスワードを自動で作ります |
| 編集 | **F2**、タイトルをダブルクリック、または右クリック。パスワード欄を空欄のままにすると、パスワードは変わりません |
| 削除 | **Del**、または右クリック（確認画面が出ます） |
| 席を離れる | **Ctrl+L** でロック（10 分間操作がないと自動でロック） |
| そのほか | **≡** から、再読込・バックアップ・マスターパスワードの変更・設定ファイルを開く・ロック |

**コピーしたパスワードの扱い**

- コピーしたパスワードは 30 秒後に自動で消えます。ただし、その間に別の物をコピーした場合は、そちらを消さないようにしています。
- Windows のクリップボード履歴（Win+V）やクラウド同期には残りません。

---

## 3. 設定のカスタマイズ

設定ファイルは `%APPDATA%\PwManager\config.json` です。画面の **≡** →「設定ファイルを開く」で開き、保存したあと PwManager を開き直すと反映されます（メモ帳が無い環境では、ファイルの場所をエクスプローラーで開きます）。
書かなかった項目には既定値が使われるので、変えたい項目だけを書けば十分です。

| 項目 | 既定値 | 内容 |
| --- | --- | --- |
| `ClipboardClearSeconds` | 30 | コピーしたパスワードを消すまでの秒数（0 にすると消さない） |
| `ExcludeFromClipboardHistory` | true | パスワードをクリップボード履歴やクラウド同期の対象から外す |
| `AutoLockMinutes` | 10 | 何分間操作がなければロックするか（0 にすると自動ロックしない） |
| `UnlockTimeoutSeconds` | 900 | 一度ロックを解除したあと、保管庫を開いたままにする秒数（過ぎると、使っている途中でもマスターパスワードの再入力を求める）。短いほど安全で、再入力は増える |
| `Fields` | ID, URL, 備考 | 表示・入力する項目（下で詳しく説明） |
| `Categories` | （なし） | カテゴリの候補（`Type: "Category"` の項目を作ったときだけ使う） |
| `PasswordGenerator` | 20 文字・記号あり | 「生成」で作るパスワードの長さと、使う記号 |

### 項目（Fields）を追加・変更する

例：「メール」と「社員番号」の項目を追加し、どちらもコピーできるようにする場合

```json
"Fields": [
  { "Name": "Id",    "Label": "ID",       "Copy": true },
  { "Name": "Email", "Label": "メール",   "Copy": true },
  { "Name": "EmpNo", "Label": "社員番号", "Copy": true },
  { "Name": "Url",   "Label": "URL",      "Copy": true, "Open": true },
  { "Name": "Note",  "Label": "備考",     "Multiline": true }
]
```

| キー | 意味 |
| --- | --- |
| `Name` | 保存に使う名前（英数字）。**一度使い始めたら変えないでください**（変えると、それまでに入れた値が表示されなくなります） |
| `Label` | 画面に表示する名前。いつでも自由に変えられます |
| `Copy` | 右クリックメニューに「〇〇をコピー」を出す |
| `Open` | 右クリックメニューに「〇〇を開く」を出す（http:// または https:// で始まる値だけ開きます） |
| `Sensitive` | コピーした値をパスワードと同じように扱う（一定時間で消し、履歴にも残さない） |
| `Type: "Category"` | 分類用の項目にする。検索欄の横に、その値で絞り込むリストが出る（例：`{ "Name": "Category", "Label": "分類", "Type": "Category" }`） |
| `Multiline` | 複数行で入力できるようにする |

項目を `Fields` から削除しても、保存済みのデータは消えません。あとで戻せば、また表示されます。

---

## 4. バックアップ・復元・PC の移行・アンインストール

### バックアップ（移行するとき）

新しい PC への移行や、万一に備えたいときに、手で取ります（自動では取りません）。画面の ≡ →「バックアップ」で保存先のフォルダーを選ぶか、PowerShell で次を実行します。

```powershell
Backup-PwVault -Destination E:\Backup
```

ZIP の中の保管庫データはマスターパスワードで暗号化されたままですが、念のため共有フォルダーなどには置かないでください。開くには、**バックアップを取ったときの**マスターパスワードが必要です。古いバックアップは自動では消さないので、不要になったら手で削除してください。

### 復元・新しい PC への移行

1. （新しい PC の場合）このフォルダーをコピーして `Install.ps1` を実行します。マスターパスワードを求められたら、仮のものを入力して構いません（復元すると上書きされます）。
2. PwManager の画面を閉じ、**新しく開いた** PowerShell で次を実行します（画面が開いていると、復元は止まります）。

   ```powershell
   Restore-PwVault -Path D:\Backup\PwManager\PwManager-backup-PC01-20261118-090000.zip -IncludeConfig
   ```

3. PwManager を起動し、**バックアップを取ったときのマスターパスワード**で開きます。

復元する前の保管庫は `%APPDATA%\PwManager\pre-restore-*.zip` に自動で退避されます。

> **年に 1 回は、別の PC か別のユーザーで復元を試してください。** バックアップは「元に戻せること」を確かめて初めて役に立ちます。

### マスターパスワードを変更する

画面の ≡ →「マスターパスワードの変更」を開き、今のパスワードと新しいパスワード（2 回）を入力します。PowerShell で `Set-PwMasterPassword` を実行しても変更できます（その場合は PwManager の画面を閉じておきます）。

- 保存済みのデータは、新しいパスワードで暗号化し直されます。登録し直す必要はありません。
- 変更している間だけ、変更前の保管庫を `%APPDATA%\PwManager\pre-pwchange-*.zip` に退避し、新しいパスワードで開けることを確かめたら削除します（古いパスワードで開けるファイルを残さないため）。残したいときは、PowerShell で `Set-PwMasterPassword -KeepSafetyCopy` を使います。
- それまでに取ったバックアップを復元するときは、**そのバックアップを取ったときの**（変更前の）パスワードが必要です。移行に使うなら、変更後にもう一度バックアップを取ってください。

### アンインストール

フォルダー内の `Uninstall.bat` をダブルクリックします（PowerShell から実行する場合は `powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1`）。PwManager の画面は閉じておきます。

- プログラムと、デスクトップ・スタートメニューのショートカットを削除します。
- 保管庫のデータと設定は、**既定では残します**。あとで `Install.bat` を実行すれば、そのまま使えます。
- データも削除するときは、途中の質問で `y` を選び、最後に `DELETE` と入力します。保管庫に PwManager 以外のシークレットがある場合などは、削除する前に警告します。手で取ったバックアップ（ZIP）は削除しません。
- SecretManagement / SecretStore モジュールと実行ポリシーは、ほかでも使っている可能性があるため変更しません（戻し方は最後に表示されます）。

---

## 5. Excel からの移行

1. Excel の 1 行目（見出し）を `Title`, `Password`, `Id`, `Url`, `Note` にします（`Fields` に追加した項目も使えます）。日本語の見出し（タイトル、パスワード、および `Fields` の `Label`）でも構いません。
2. 「名前を付けて保存」で **CSV UTF-8** を選んで保存します。
3. PowerShell で次を実行します。

   ```powershell
   Import-PwCsv -Path C:\work\passwords.csv
   # Excel の「CSV (コンマ区切り)」で保存した場合
   Import-PwCsv -Path C:\work\passwords.csv -Encoding Default
   ```

4. **取り込みが済んだら、CSV と元の Excel ファイルを削除し、ごみ箱も空にしてください。**

取り込み先の項目が無い列（たとえば「メール」）があると、データを取りこぼさないよう、取り込まずに止まります。その列も残したいときは `Fields` に項目を追加してから（[項目を追加・変更する](#項目fieldsを追加変更する)）、要らないときは `-IgnoreUnknownColumns` を付けて実行します。

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
| `New-PwEntry Amazon -Fields @{ ID = 'taro'; URL = 'https://…' } -Generate` | 登録する（`-Generate` でパスワードを生成。付けなければ入力を求める） |
| `Set-PwEntry Amazon -Fields @{ URL = 'https://…' }` | 指定した項目だけ変える（`-Title` でタイトル、`-Generate` / `-PromptPassword` でパスワード） |
| `Remove-PwEntry Amazon` | 削除する（確認あり） |
| `New-PwPassword -Length 24` | パスワードを生成する |
| `Edit-PwConfig` | 設定ファイルを開く |
| `Backup-PwVault` / `Restore-PwVault` | バックアップ・復元 |
| `Set-PwMasterPassword` | マスターパスワードを変更する |
| `Import-PwCsv` / `Export-PwCsv` | CSV の取り込み・書き出し |

- パスワードは引数に平文で書かず、`-Generate` で生成するか、入力欄に入力します（コマンドの履歴に残さないため）。
- `Get-PwEntry 旧 | Remove-PwEntry` のように、検索結果をパイプで渡すこともできます。検索語に複数のエントリが当てはまるときは、選ぶ画面が出ます。
- 保管庫に書き込むコマンド（登録・編集・削除・CSV の取り込み・マスターパスワードの変更）は、PwManager の画面を閉じてから実行します。

---

## 7. セキュリティ上の注意

- パスワードは SecretStore によって暗号化して保存されます。開くにはマスターパスワードが必要です。
- **いちばん大事なのはマスターパスワードの強さです。** 保管庫のファイルやバックアップの ZIP が持ち出されると、PwManager を通さずに総当たりで試されます（オフライン攻撃）。これを防げるのはパスワードの長さだけなので、長めのフレーズ（たとえば 4〜5 語をつなげたもの）にしてください。
- 画面でのマスターパスワードの入力に続けて失敗すると、5 回目から次に試せるまでの待ち時間が延びます（5 秒から倍々に、最長 5 分）。次に正しく開いたとき、それまでに失敗した回数と日時を表示します。心当たりがなければ、マスターパスワードを変更してください。
- **秘密にすべき内容はパスワード欄に入れてください。** SecretManagement の仕様上、ID・URL・備考などのメタデータは、機密情報を入れることを前提にしていません。PIN や秘密の質問の答えなどは、備考に書かずに別のエントリとして登録してください。
- 追加・更新・削除・バックアップ・ロック解除の失敗の記録が `%APPDATA%\PwManager\audit.log` に残ります。ログは暗号化されないため、パスワードもタイトル（サービス名）も書かず、エントリの ID（`pwm:…`）だけを記録します。1 MB（約 1 万件）を超えると `audit.old.log` に移し、その 1 つ前の記録は消えます。
- 画面のロック（Ctrl+L・自動ロック）は、画面の表示を消して、再開時にマスターパスワードを確かめるものです。保管庫そのものは `UnlockTimeoutSeconds`（既定 15 分）の間、PwManager のプロセスの中で開いたままです。席を離れるときは Windows のロック（**Win+L**）も併用してください。
- ノート PC の紛失・盗難に備えて、BitLocker（ドライブの暗号化）を有効にしておくことをおすすめします。
- 会社の規程で、業務用パスワードの保管方法が定められている場合は、それに従ってください。

---

## 8. 困ったときは

| 症状 | 対処 |
| --- | --- |
| ショートカットから起動しない | PowerShell で `pwm` を実行すると、エラーの内容が表示されます |
| 「設定ファイルの書式が正しくありません」と表示される | `config.json` の `,` や `"` の過不足を確認します。分からなくなったら、ファイルを削除すれば既定値に戻ります |
| マスターパスワードを忘れた | 復元する方法はありません。`Uninstall.bat` でデータも削除してから `Install.bat` で入れ直すと、新しいマスターパスワードで使い始められますが、**保存したデータはすべて消えます** |
| マスターパスワードを変えたら、古いバックアップが開けない | バックアップは、取ったときのマスターパスワードで暗号化されています。そのときのパスワードで開いてください |
| 「スクリプトの実行が無効」と表示される | 会社のポリシーで制限されている可能性があります。情報システム担当に相談してください |
| 文字化けする | `.ps1` や `.psm1` を編集したときは、**UTF-8（BOM 付き）** で保存してください |

---

## 9. ファイルの構成（保守する人向け）

```text
PwManager\                 … 配布用フォルダー
  Install.bat / Install.ps1      … セットアップ・アップデート
  Uninstall.bat / Uninstall.ps1  … アンインストール（既定ではデータを残す）
  README.md
  tests\                   … 自動テスト（配布・インストールの対象外）
  tools\Build-Release.ps1  … リリース用フォルダー（release\、git の管理対象外）を作る
  PwManager\               … 本体（Documents\WindowsPowerShell\Modules\PwManager にコピーされる）
    PwManager.psd1         … バージョン情報（更新するときは ModuleVersion を上げる）
    PwManager.psm1         … 共通の定数と、下の各ファイルの読み込み
    Config.ps1             … 設定・状態・監査ログ
    Vault.ps1              … 保管庫の操作（登録・更新・削除・一覧）
    Clipboard.ps1          … クリップボード（コピー・自動消去）
    Password.ps1           … パスワード生成
    Backup.ps1             … バックアップ・復元
    Csv.ps1                … CSV の取り込み・書き出し
    Setup.ps1              … 初期設定とショートカット
    List.ps1               … 一覧のデータ（表の作成・検索条件・1 行単位の更新）。画面に依存せず、tests\List.Tests.ps1 で検証
    Cli.ps1                … 登録・編集・削除のコマンド（New-PwEntry / Set-PwEntry / Remove-PwEntry）
    Gui.Dialogs.ps1        … 画面の共通部品とダイアログ（ロック解除・登録/編集）
    Gui.List.ps1           … 一覧の画面側（List.ps1 のデータをグリッド・検索欄に結び付ける）
    Gui.Actions.ps1        … 画面の操作（コピー・登録・編集・削除・バックアップ・ロック）
    Gui.Main.ps1           … メイン画面と、画面の状態（$ui）の定義 New-PwUiState。$ui に項目を足すときはここに追加する
    Launch.ps1             … ショートカットから呼び出される起動スクリプト
    config.default.json    … 設定の既定値

%APPDATA%\PwManager\       … config.json / audit.log / audit.old.log / unlock.json（入力の失敗の記録） / pre-restore-*.zip
%LOCALAPPDATA%\Microsoft\PowerShell\secretmanagement\localstore\  … 暗号化された保管庫（SecretStore が管理）
```

### 修正するときの手順

1. 修正したら、テストを実行します（追加のモジュールは不要で、実際の保管庫やデータには触れません）。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
   ```

   クリップボードのテストは、実行中にクリップボードを書き換えます（終わると元のテキストに戻します）。

   画面の動作や軽さは、模擬データで確かめられます（実際の保管庫には触れません。マスターパスワードは何を入力しても開きます）。

   ```powershell
   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Demo-Gui.ps1 -Count 3000
   ```

2. `PwManager.psd1` の `ModuleVersion` を上げ、git にコミットします。
3. リリース用のフォルダーを作ります（テストを実行し、成功したときだけ作ります）。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1
   ```

   `release\PwManager-<バージョン>\` と、その ZIP ができます。利用者にはこれを渡します（テストや git の情報は含まれません）。配布するファイルを増やしたときは、`Build-Release.ps1` の一覧にも追加します。
4. 配る前に、Windows Sandbox で確かめます。`release\PwManager-Sandbox.wsb` をダブルクリックすると、リリースフォルダーがデスクトップの `PwManager` に読み取り専用で割り当てられた Sandbox が開くので、そこで `Install.bat` を実行します。Sandbox でテストやデモ（`tests\Demo-Gui.ps1`）も動かしたいときは、`-IncludeTests` を付けて作ります。
5. 利用者は、新しいフォルダーで `Install.bat` を実行すれば更新されます。

SecretManagement / SecretStore は、`Install.ps1` でメジャーバージョン 1 系に固定しています。2.0 以降が出たら、テストと実際の画面で動作を確かめてから、`Install.ps1` の `-MaximumVersion` を上げてください。

**保存形式（スキーマ v1）**

- シークレットの名前は `pwm:<GUID>` です。こうしておくと、タイトルを変えてもデータは同じまま残り、同じサービスで複数のアカウントを登録することもできます。
- シークレットの本体はパスワード（SecureString）です。
- メタデータには、`Title`、`Created`、`Updated`、`Schema`、そして `Fields` で定義した各項目が入ります。
- 名前が `pwm:` で始まらないシークレットは、このツールでは表示しません。ほかの用途のシークレットと同じ保管庫に共存できます。
