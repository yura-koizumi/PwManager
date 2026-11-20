#Requires -Version 5.1
<#
  PwManager セットアップ / アップデート

  実行方法（このフォルダーで）:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1

  何度実行しても安全です。アップデート時も同じ手順で、設定と保管庫のデータはそのまま残ります。
#>
[CmdletBinding()]
param([switch]$NoShortcut)

$ErrorActionPreference = 'Stop'
Write-Host '=== PwManager セットアップ ===' -ForegroundColor Cyan

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Windows PowerShell 5.1（スタートメニューの「Windows PowerShell」）で実行してください。'
}

$m = $null
if ([System.Threading.Mutex]::TryOpenExisting('Local\PwManager-GUI', [ref]$m)) {
    $m.Dispose()
    throw 'PwManager の画面が開いています。閉じてから、もう一度実行してください。'
}
# --- プログラムの置き場所 ---------------------------------------------------------------
# PwManager と、使う SecretManagement / SecretStore を、%LOCALAPPDATA%\Programs\PwManager\Modules にまとめて置く。
# Documents の下（PowerShell の既定の置き場所）は OneDrive で同期されることがあり、クラウド側でプログラムを
# 書き換えられると、次に開いたときにマスターパスワードを盗まれうるため。LOCALAPPDATA は同期されず、このユーザーだけが書ける。
$root    = Join-Path $env:LOCALAPPDATA 'Programs\PwManager'
$modules = Join-Path $root 'Modules'
New-Item -ItemType Directory -Path $modules -Force | Out-Null
if (($env:PSModulePath -split ';') -notcontains $modules) { $env:PSModulePath = "$modules;$env:PSModulePath" }   # このあとの処理でも、ここのものを使う

# --- 1. 必要なモジュール（Microsoft 製、PowerShell Gallery から取得） -------------------
$need = 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore'
# フォルダーがあるだけ（ダウンロードが途中で止まったなど）では入っているとみなさず、psd1 まであるかで判断する
$missing = @($need | Where-Object { -not (Get-ChildItem -Path (Join-Path $modules "$_\*\$_.psd1") -ErrorAction SilentlyContinue) })
if ($missing.Count -gt 0) {
    Write-Host "[1/4] モジュールを導入します: $($missing -join ', ')"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # 社内プロキシ環境向け（プロキシが無い環境でも影響なし）
    try { [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials } catch { }
    $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'2.8.5.201' }
    if (-not $nuget) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null }
    # 動作確認済みのメジャーバージョン 1 系に固定（2.0 以降は互換性を確認してから上限を上げる）
    foreach ($n in $missing) { Save-Module -Name $n -Repository PSGallery -Path $modules -MaximumVersion '1.999.999' -Force }
    # SecretStore の依存として、上限を超える SecretManagement が一緒に保存されることがあるので、1 系以外は消す
    foreach ($n in $need) {
        Get-ChildItem -LiteralPath (Join-Path $modules $n) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $v = $null; [version]::TryParse($_.Name, [ref]$v) -and $v.Major -ne 1 } |
            Remove-Item -Recurse -Force
    }
    Get-ChildItem -LiteralPath $modules -Recurse -File | Unblock-File
} else {
    Write-Host '[1/4] モジュールは導入済みです。'
}

# 新しく開く PowerShell でも pwm などのコマンドを使えるよう、モジュールを探す場所（ユーザーの PSModulePath）に足す。
# ユーザーの PSModulePath があると、PowerShell は Documents の場所を自分では足さなくなるので、それも入れておく
$userPaths = @([Environment]::GetEnvironmentVariable('PSModulePath', 'User') -split ';' | Where-Object { $_ })
if (@($userPaths | ForEach-Object { $_.TrimEnd('\') }) -notcontains $modules.TrimEnd('\')) {   # 末尾の \ の有無は区別しない
    if ($userPaths.Count -eq 0) { $userPaths = @(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules') }
    [Environment]::SetEnvironmentVariable('PSModulePath', ((@($modules) + $userPaths) -join ';'), 'User')
}


# --- 2. 実行ポリシー（自分のPCで作ったスクリプトを実行できるようにする） --------------------
$cu = Get-ExecutionPolicy -Scope CurrentUser
$lm = Get-ExecutionPolicy -Scope LocalMachine
$gpo = @(@('MachinePolicy', 'UserPolicy' | ForEach-Object { Get-ExecutionPolicy -Scope $_ }) | Where-Object { $_ -ne 'Undefined' })   # 1 つだけでも配列にする（$gpo[0] が 1 文字目にならないように）
if ($gpo) {
    Write-Host "[2/4] 実行ポリシーはグループポリシーで管理されています（$($gpo -join ', ')）。変更しません。"
    if ($gpo[0] -in 'Restricted', 'AllSigned') {
        # 一番強いポリシーが Restricted / AllSigned だと、署名の無い PwManager はショートカットからも起動できない（画面も出ない）
        Write-Warning ("この PC では、会社などの設定（$($gpo[0])）により PwManager を実行できません。" +
                       'PC の管理者に、実行ポリシーを RemoteSigned にしてもらえるか相談してください。')
    }
} elseif ($cu -in 'Restricted', 'AllSigned' -or ($cu -eq 'Undefined' -and $lm -in 'Restricted', 'AllSigned', 'Undefined')) {
    # -ExecutionPolicy Bypass で起動していると Process スコープが優先されるため、
    # 設定は保存されても ExecutionPolicyOverride が投げられる。これは成功扱いにする。
    try {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    } catch [System.Security.SecurityException] {
        if ($_.FullyQualifiedErrorId -notlike 'ExecutionPolicyOverride*') { throw }
    }
    Write-Host '[2/4] 実行ポリシーを RemoteSigned（現在のユーザーのみ）に設定しました。'
} else {
    Write-Host "[2/4] 実行ポリシーは変更不要です（CurrentUser=$cu, LocalMachine=$lm）。"
}

# --- 3. プログラムを配置 ------------------------------------------------------------------
$src = Join-Path $PSScriptRoot 'PwManager'
$dst = Join-Path $modules 'PwManager'
# 以前の版は Documents の下に置いていた。残しておくと同期で書き換えられうるので消す（データは別の場所なので影響しない）
$oldDst = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\PwManager'
if ((Test-Path -LiteralPath (Join-Path $oldDst 'PwManager.psd1')) -and $oldDst.TrimEnd('\') -ne $dst.TrimEnd('\')) {
    Remove-Item -LiteralPath $oldDst -Recurse -Force
    Write-Host "      以前の場所のプログラムを削除しました: $oldDst"
}
if ((Resolve-Path $src).Path.TrimEnd('\') -ne $dst.TrimEnd('\')) {
    New-Item -ItemType Directory -Path $modules -Force | Out-Null
    # 入れ直しのとき、コピーに失敗しても今のプログラムが消えたままにならないよう、先に横へコピーしてから入れ替える
    $new = "$dst.new"
    if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
    Copy-Item -LiteralPath $src -Destination $new -Recurse
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }  # プログラムのみ。設定・データは別の場所
    Rename-Item -LiteralPath $new -NewName (Split-Path $dst -Leaf)
}
Get-ChildItem -LiteralPath $dst -Recurse -File | Unblock-File
$psd = Import-PowerShellDataFile (Join-Path $dst 'PwManager.psd1')
$ver = $psd.ModuleVersion + $(if ($psd.PrivateData.PSData.Prerelease) { '-' + $psd.PrivateData.PSData.Prerelease })
Write-Host "[3/4] プログラムを配置しました: $dst (v$ver)"

# --- 4. 初期設定（設定ファイル・保管庫・マスターパスワード）とショートカット -------------------
Write-Host '[4/4] 初期設定'
Import-Module (Join-Path $dst 'PwManager.psd1') -Force
Initialize-PwManager
if (-not $NoShortcut) {
    try { Install-PwShortcut } catch { Write-Warning "ショートカットを作成できませんでした: $($_.Exception.Message)" }
}

Write-Host ''
Write-Host 'セットアップが完了しました。' -ForegroundColor Green
Write-Host '  起動: デスクトップの「PwManager」、または PowerShell で  pwm（pwm などのコマンドは、新しく開いた PowerShell で使えます。Windows ターミナルや VS Code は、いったん全部閉じてから開き直してください）'
Write-Host "  プログラムの場所: $dst"
