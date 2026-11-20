#Requires -Version 5.1
<#
  PwManager アンインストール

  実行方法（このフォルダーで）:
    Uninstall.bat をダブルクリック、または
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1

  プログラムとショートカットを削除します。
  保管庫のデータと設定は、既定では残します（あとで Install.bat を実行すれば、そのまま使えます）。
  データも削除するときは、途中の質問で選ぶか、-RemoveData を付けて実行します。
  PwManager と一緒に入れた SecretManagement / SecretStore（%LOCALAPPDATA%\Programs\PwManager）も削除します。
  ほかの場所に入っている SecretManagement / SecretStore と、実行ポリシーは変更しません。
#>
[CmdletBinding()]
param([switch]$RemoveData)

$ErrorActionPreference = 'Stop'
Write-Host '=== PwManager アンインストール ===' -ForegroundColor Cyan

# 場所は PwManager.psm1 と同じ（モジュールが消えていても動くよう、ここで直接決める）
$dataDir   = Join-Path $env:APPDATA 'PwManager'
$storeDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
$root      = Join-Path $env:LOCALAPPDATA 'Programs\PwManager'   # Install.ps1 と同じ
$modules   = Join-Path $root 'Modules'
$moduleDir = Join-Path $modules 'PwManager'
$oldModuleDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\PwManager'   # 以前の版の置き場所
if (($env:PSModulePath -split ';') -notcontains $modules) { $env:PSModulePath = "$modules;$env:PSModulePath" }   # 一緒に入れた SecretManagement を使う
$vaultName = 'PwVault'
$configPath = Join-Path $dataDir 'config.json'
if (Test-Path -LiteralPath $configPath) {
    try {
        $c = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.VaultName) { $vaultName = [string]$c.VaultName }
    } catch { }
}

# 保管庫の中身を確かめるときに使うので、プログラムを消す前に読み込んでおく（このフォルダーのもの、なければインストール済みのもの）
$pwm = $null
foreach ($psd in (Join-Path $PSScriptRoot 'PwManager\PwManager.psd1'), (Join-Path $moduleDir 'PwManager.psd1'), (Join-Path $oldModuleDir 'PwManager.psd1')) {
    if (Test-Path -LiteralPath $psd) {
        try { $pwm = Import-Module $psd -Force -PassThru -ErrorAction Stop; break } catch { }
    }
}

$m = $null
if ([System.Threading.Mutex]::TryOpenExisting('Local\PwManager-GUI', [ref]$m)) {
    $m.Dispose()
    throw 'PwManager の画面が開いています。閉じてから、もう一度実行してください。'
}

# --- 1. ショートカット ---------------------------------------------------------------
foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    $lnk = Join-Path $dir 'PwManager.lnk'
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host "[1/3] ショートカットを削除しました: $lnk" }
}

# --- 2. プログラム -------------------------------------------------------------------
$removed = $false
foreach ($d in $moduleDir, $oldModuleDir) {
    if (Test-Path -LiteralPath (Join-Path $d 'PwManager.psd1')) { Remove-Item -LiteralPath $d -Recurse -Force; Write-Host "[2/3] プログラムを削除しました: $d"; $removed = $true }
}
if (-not $removed) { Write-Host '[2/3] プログラムはインストールされていません。' }

# --- 3. 保管庫のデータと設定（既定では残す） ---------------------------------------------
function Write-Kept {
    Write-Host '[3/3] 保管庫のデータと設定は残しました。Install.bat を実行すれば、そのまま使えます。' -ForegroundColor Green
    if (Test-Path -LiteralPath $storeDir) { Write-Host "  保管庫: $storeDir" }
    if (Test-Path -LiteralPath $dataDir)  { Write-Host "  設定  : $dataDir" }
    Write-Host '  あとでデータも削除するときは、もう一度 Uninstall.bat を実行してください（プログラムを削除したあとでも使えます）。'
}

if (-not (Test-Path -LiteralPath $storeDir) -and -not (Test-Path -LiteralPath $dataDir)) {
    Write-Host '[3/3] 保管庫のデータと設定はありません。'
} else {
    if (-not $RemoveData) {
        Write-Host ''
        $ans = Read-Host '保管庫のデータと設定も削除しますか？ 削除すると、保存したパスワードは二度と取り出せません [y/N]'
        $RemoveData = $ans -match '^\s*(y|yes)\s*$'
    }
    if (-not $RemoveData) {
        Write-Kept
    } else {
        # SecretStore のデータ本体は、このツール以外の用途と共通。ほかのシークレットが無いか確かめる
        $warnings = New-Object System.Collections.Generic.List[string]
        $hasSecretManagement = [bool](Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)
        if ($hasSecretManagement) {
            $otherVaults = @(Get-SecretVault -ErrorAction SilentlyContinue |
                Where-Object { $_.ModuleName -eq 'Microsoft.PowerShell.SecretStore' -and $_.Name -ne $vaultName })
            foreach ($v in $otherVaults) { $warnings.Add("SecretStore を使う別の保管庫「$($v.Name)」も登録されています（データ本体は共通のため、そのデータも消えます）。") }
            if (Test-Path -LiteralPath $storeDir) {
                Write-Host ''
                $pw = Read-Host 'マスターパスワード（ほかの用途のシークレットが無いか確かめます。分からなければ空欄のまま Enter）' -AsSecureString
                if ($pw.Length -gt 0 -and -not $pwm) {
                    $warnings.Add('PwManager のプログラムが見つからないため、保管庫の中身は確かめていません。')
                } elseif ($pw.Length -gt 0) {
                    try {
                        & $pwm { param($p) [void](Invoke-PwUnlock $p) } $pw   # 保管庫キーはマスターパスワードから取り出す
                        $infos = @(Get-SecretInfo -Vault $vaultName)
                        $mine = @($infos | Where-Object { $_.Name -like 'pwm:*' }).Count
                        $infos = @($infos | Where-Object { $_.Name -notlike 'pwm-prev:*' })   # 変更前のパスワード（PwManager のもの）は数えない
                        $other = $infos.Count - $mine
                        Write-Host "  PwManager のエントリ: $mine 件"
                        if ($other -gt 0) { $warnings.Add("PwManager 以外のシークレットが $other 件あります（これも消えます）。") }
                    } catch {
                        $warnings.Add("保管庫の中身を確かめられませんでした（$($_.Exception.Message)）。")
                    }
                } else {
                    $warnings.Add('保管庫の中身は確かめていません。')
                }
            }
        }
        # SecretManagement が無い（前にプログラムだけ消したあと、など）と中身を確かめられない。黙って進めずに知らせる
        if (-not $hasSecretManagement -and (Test-Path -LiteralPath $storeDir)) {
            $warnings.Add('SecretManagement が見つからないため、保管庫に PwManager 以外のシークレットが無いかは確かめていません（ある場合は、それも消えます）。')
        }

        Write-Host ''
        Write-Host '次のものを削除します。' -ForegroundColor Yellow
        if (Test-Path -LiteralPath $storeDir) { Write-Host "  保管庫（暗号化されたデータ）: $storeDir" }
        if (Test-Path -LiteralPath $dataDir)  { Write-Host "  設定・保管庫キー・監査ログ・退避ファイル: $dataDir" }
        foreach ($w in $warnings) { Write-Warning $w }
        Write-Host '  ※ 手で取ったバックアップ（ZIP）は削除しません。不要なら手で削除してください。'
        $confirm = Read-Host '本当に削除するときは DELETE と入力してください（それ以外は中止してデータを残します）'
        if ($confirm -cne 'DELETE') {
            Write-Kept
        } else {
            if ($hasSecretManagement -and (Get-SecretVault -Name $vaultName -ErrorAction SilentlyContinue)) {
                Unregister-SecretVault -Name $vaultName
            }
            foreach ($p in $storeDir, $dataDir) {
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
            }
            Write-Host '[3/3] 保管庫のデータと設定を削除しました。' -ForegroundColor Green
        }
    }
}

# --- 最後に、一緒に入れた SecretManagement / SecretStore と、モジュールを探す場所の設定を消す ----------
# （データを消すときに SecretManagement を使うので、最後にする）
# データを残したときも、保管庫の登録は外す（これから消す SecretStore を指したままだと、ほかで SecretManagement を
# 使ったときにエラーになるため）。登録を外してもデータはそのままで、Install.bat を実行すれば登録し直す
try {
    if ((Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement) -and (Get-SecretVault -Name $vaultName -ErrorAction SilentlyContinue)) {
        Unregister-SecretVault -Name $vaultName
    }
} catch { Write-Warning "保管庫の登録を外せませんでした（$($_.Exception.Message)）。" }
Remove-Module PwManager, Microsoft.PowerShell.SecretStore, Microsoft.PowerShell.SecretManagement -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $root) {
    try {
        Remove-Item -LiteralPath $root -Recurse -Force
        Write-Host "一緒に入れた SecretManagement / SecretStore を削除しました: $root"
    } catch {
        # 読み込んだ DLL はこのプロセスが終わるまで消せない。終わるのを待って消す PowerShell を、画面を出さずに起動する
        $cmd = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; Remove-Item -LiteralPath '$($root -replace "'", "''")' -Recurse -Force -ErrorAction SilentlyContinue"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $enc
        Write-Host "一緒に入れた SecretManagement / SecretStore は、このウィンドウの処理が終わったあとに削除します: $root"
    }
}
# モジュールを探す場所から、Install.ps1 が足したものを外す（末尾の \ の有無は区別しない）
$norm = { param($p) ([string]$p).TrimEnd('\') }
$before = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
$userPaths = @($before -split ';' | Where-Object { $_ -and (& $norm $_) -ne (& $norm $modules) })
$documents = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
# Install.ps1 が足した Documents の場所だけが残るなら、設定ごと消す（PowerShell の既定に戻る）
if ($userPaths.Count -eq 0 -or ($userPaths.Count -eq 1 -and (& $norm $userPaths[0]) -eq (& $norm $documents))) { $userPaths = @() }
$after = if ($userPaths.Count) { $userPaths -join ';' } else { $null }
if ($after -ne $before) { [Environment]::SetEnvironmentVariable('PSModulePath', $after, 'User') }

Write-Host ''
Write-Host 'アンインストールが完了しました。' -ForegroundColor Green
Write-Host '  実行ポリシーは変更していません。元に戻すときは次を実行します:'
Write-Host '    Set-ExecutionPolicy Undefined -Scope CurrentUser'
