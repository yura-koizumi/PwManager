#Requires -Version 5.1
<#
  PwManager - SecretManagement / SecretStore を使ったローカルパスワード管理

  データの置き場所
    プログラム : このフォルダー（Install.ps1 で Documents\WindowsPowerShell\Modules\PwManager にコピー）
    設定・ログ : %APPDATA%\PwManager\        (config.json / audit.log / vaultkey.json = 保管庫キー)
    保管庫     : %LOCALAPPDATA%\Microsoft\PowerShell\secretmanagement\localstore  (SecretStore が管理・暗号化)

  エントリの保存形式（スキーマ v1）
    シークレット名 : "pwm:" + GUID       … タイトル変更や同名サービスの複数アカウントに対応するため
    シークレット本体: パスワード (SecureString)
    メタデータ      : Title, Created, Updated, Schema, および config の Fields に定義した項目
#>

$ErrorActionPreference = 'Stop'

$script:ModuleRoot    = $PSScriptRoot
$script:SecretPrefix  = 'pwm:'
$script:SchemaVersion = 1
$script:DataDir       = Join-Path $env:APPDATA 'PwManager'
$script:ConfigPath    = Join-Path $script:DataDir 'config.json'
$script:AuditPath     = Join-Path $script:DataDir 'audit.log'
$script:StoreRoot     = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement'
$script:ReservedKeys  = @('Name', 'Title', 'Password', 'Created', 'Updated', 'Schema')
$script:DateFormat    = 'yyyy-MM-dd HH:mm:ss'
$script:PinnedConfig  = $null   # 画面の表示中だけ設定される（Get-PwConfig 参照）
$script:GuiMutexName  = 'Local\PwManager-GUI'
$script:AuditMaxBytes = 1MB     # これを超えたら audit.old.log に切り替える（約 1 万件分）
# 版（例: 0.5.0-beta）。PwManager.psd1 の ModuleVersion と Prerelease から作る（画面のタイトルに出す）
#（読み込み中はモジュールの Version がまだ入っていないので、psd1 を直接読む）
$script:Version = & {
    $psd = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'PwManager.psd1')
    $psd.ModuleVersion + $(if ($psd.PrivateData.PSData.Prerelease) { '-' + $psd.PrivateData.PSData.Prerelease })
}

# 機能ごとのファイルを読み込む
#   Config      設定・監査ログ                Key         保管庫キー（マスターパスワード・回復キー）
#   Vault       保管庫の操作
#   Clipboard   クリップボード                Password    パスワード生成
#   Backup      バックアップ・復元            Csv         CSV の取り込み・書き出し
#   Setup       初期設定とショートカット      List        一覧のデータ（画面に依存しない）
#   Cli         登録・編集・削除のコマンド      Help        コマンドの一覧（Get-PwHelp）
#   Gui.*       画面（Dialogs: 共通部品とダイアログ / List: 一覧 / Actions: 操作 / Main: メイン画面）
foreach ($file in 'Config', 'Key', 'Vault', 'Clipboard', 'Password', 'Backup', 'Csv', 'Setup', 'List', 'Cli',
                  'Help', 'Gui.Dialogs', 'Gui.List', 'Gui.Actions', 'Gui.Main') {
    . (Join-Path $PSScriptRoot "$file.ps1")
}

New-Alias -Name pwm -Value Show-PwManager -Force
