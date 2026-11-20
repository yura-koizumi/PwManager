#Requires -Version 5.1
<#
  リリース用フォルダーを作る（開発用のファイルを含まない、利用者に渡す一式）

  実行方法（リポジトリの一番上で）:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1 -IncludeTests   # Sandbox でテストやデモも動かすとき

  作られるもの（release\ は git の管理対象外）:
    release\PwManager-<バージョン>\      … 配布する一式（Install.bat から使える）
    release\PwManager-<バージョン>.zip   … 上を ZIP にしたもの（そのまま配れる）
    release\PwManager-Sandbox.wsb        … ダブルクリックすると、上のフォルダーを
                                           デスクトップの PwManager に読み取り専用で割り当てた Windows Sandbox が開く

  作る前に自動テストを実行し、失敗したら作らない（-SkipTests で省略）。

  版の付け方（CHANGELOG.md の先頭にも書いてある）:
    0.5.<番号>-beta。リリースのたびに最後の番号だけを 1 つ上げる（小さな修正だけでも上げる）。
    -Bump を付けると、テストが通ったあとに番号を 1 つ上げ（PwManager.psd1）、
    CHANGELOG.md の「次の版」に書いた変更を、その版の見出しに移す（「次の版」が空なら止まる）。
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Release.ps1 -Bump
#>
[CmdletBinding()]
param(
    [switch]$IncludeTests,
    [switch]$SkipTests,
    [switch]$Bump
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$psdPath = Join-Path $root 'PwManager\PwManager.psd1'
$changelogPath = Join-Path $root 'CHANGELOG.md'
$nextHeading = '## 次の版'

if ($Bump) {
    # テストの前に「次の版」が書いてあるかだけ確かめる（書き忘れに、テストを待たずに気づけるように）
    $changelog = [IO.File]::ReadAllText($changelogPath)
    $m = [regex]::Match($changelog, "(?ms)^$nextHeading\r?\n(.*?)(?=^## |\z)")
    if (-not $m.Success -or $m.Groups[1].Value -notmatch '(?m)^- ') {
        throw "CHANGELOG.md の「$nextHeading」に変更を書いてから、もう一度実行してください。"
    }
}

if (-not $SkipTests) {
    Write-Host '自動テストを実行します...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-Tests.ps1') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'テストが失敗したため、リリースを作りませんでした。' }
}

# -Bump で版を上げたあとに失敗したら、psd1 と CHANGELOG.md を元に戻す（やり直すとき「次の版」が空で止まらないように）
$bumpBackup = $null
trap {
    if ($bumpBackup) {
        [IO.File]::WriteAllText($psdPath, $bumpBackup.Psd, (New-Object Text.UTF8Encoding $true))
        [IO.File]::WriteAllText($changelogPath, $bumpBackup.Changelog, (New-Object Text.UTF8Encoding $false))
        Write-Host 'リリースを作れなかったので、版と CHANGELOG.md を元に戻しました。' -ForegroundColor Yellow
    }
    break
}

if ($Bump) {
    # 最後の番号を 1 つ上げる（psd1 は BOM 付きのまま書き戻す）
    $psdText = [IO.File]::ReadAllText($psdPath)
    $bumpBackup = @{ Psd = $psdText; Changelog = $changelog }
    $vm = [regex]::Match($psdText, "ModuleVersion\s*=\s*'(\d+)\.(\d+)\.(\d+)'")
    if (-not $vm.Success) { throw 'PwManager.psd1 の ModuleVersion が読めません。' }
    $newVersion = '{0}.{1}.{2}' -f $vm.Groups[1].Value, $vm.Groups[2].Value, ([int]$vm.Groups[3].Value + 1)
    $psdText = $psdText.Remove($vm.Index, $vm.Length).Insert($vm.Index, "ModuleVersion     = '$newVersion'")
    [IO.File]::WriteAllText($psdPath, $psdText, (New-Object Text.UTF8Encoding $true))
    $pre = (Import-PowerShellDataFile $psdPath).PrivateData.PSData.Prerelease
    $label = $newVersion + $(if ($pre) { "-$pre" })
    # 「次の版」の変更を、その版の見出しの下に移し、「次の版」は空にする
    $changelog = $changelog -replace "(?m)^$nextHeading\r?\n", "$nextHeading`n`n## $label（$((Get-Date).ToString('yyyy-MM-dd'))）`n"
    [IO.File]::WriteAllText($changelogPath, $changelog, (New-Object Text.UTF8Encoding $false))
    Write-Host "版を $label に上げました（PwManager.psd1・CHANGELOG.md）。コミットしてからタグ v$label を付けてください。" -ForegroundColor Green
}

$psd = Import-PowerShellDataFile $psdPath
$ver = $psd.ModuleVersion + $(if ($psd.PrivateData.PSData.Prerelease) { '-' + $psd.PrivateData.PSData.Prerelease })
Write-Host "=== PwManager v$ver のリリースを作ります ===" -ForegroundColor Cyan

# 配布に含めるもの（ここに無いファイルは含めない。新しいファイルを足したときは、ここにも追加する）
$rootFiles   = 'Install.bat', 'Install.ps1', 'Uninstall.bat', 'Uninstall.ps1', 'README.md', 'CHANGELOG.md', 'LICENSE'
$moduleFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'PwManager') -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' -or $_.Name -eq 'config.default.json' })

$releaseDir = Join-Path $root 'release'
$out = Join-Path $releaseDir "PwManager-$ver"
$zip = "$out.zip"
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
foreach ($p in $out, $zip) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }

New-Item -ItemType Directory -Path (Join-Path $out 'PwManager') -Force | Out-Null
foreach ($f in $rootFiles) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $out }
foreach ($f in $moduleFiles) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $out 'PwManager') }
if ($IncludeTests) {
    Copy-Item -LiteralPath (Join-Path $root 'tests') -Destination $out -Recurse
}

# 想定外のファイル（設定・ログ・CSV など個人データになり得るもの）が紛れ込んでいないか確かめる
$allowed = '\.(ps1|psm1|psd1|bat|md)$|^config\.default\.json$|^LICENSE$'
$unexpected = @(Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Name -notmatch $allowed })
if ($unexpected) { throw "想定外のファイルが含まれています: $($unexpected.FullName -join ', ')" }

# Windows PowerShell 5.1 の Compress-Archive はフォルダーの区切りを \ で書き、エクスプローラー以外の展開ソフトでは
# 「PwManager\Setup.ps1」という名前のファイルになることがある。ZIP の決まりどおり / で書く
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($f in Get-ChildItem -LiteralPath $out -Recurse -File) {
        $entry = $f.FullName.Substring($out.Length + 1) -replace '\\', '/'
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, 'Optimal')
    }
} finally { $archive.Dispose() }

# Windows Sandbox の設定（ホストのフォルダーは読み取り専用で割り当てるため、Sandbox から書き換えられない）
#   軽くするため、メモリーを 2 GB にし、マイク・カメラ・プリンターは使わない。
#   ネットワーク（初回のモジュール導入に必要）とクリップボード（結果を貼り付けるため）は使う。
#   Windows 11 はメモ帳の起動をストア版に切り替える（IFEO）が、Sandbox にはストア版が無いため、起動時にその切り替えを外す。
#   Sandbox に従来のメモ帳も無いときに備えて、ホストのものを C:\Tools に割り当てておく
$wsb = Join-Path $releaseDir 'PwManager-Sandbox.wsb'
$sandboxFolder = 'C:\Users\WDAGUtilityAccount\Desktop\PwManager'
$tools = Join-Path $releaseDir 'sandbox-tools'
if (Test-Path -LiteralPath $tools) { Remove-Item -LiteralPath $tools -Recurse -Force }
New-Item -ItemType Directory -Path $tools | Out-Null
$sys = Join-Path $env:SystemRoot 'System32'
if (Test-Path -LiteralPath (Join-Path $sys 'notepad.exe')) {
    Copy-Item -LiteralPath (Join-Path $sys 'notepad.exe') -Destination $tools
    foreach ($lang in 'ja-JP', 'en-US') {
        $mui = Join-Path $sys "$lang\notepad.exe.mui"
        if (Test-Path -LiteralPath $mui) {
            New-Item -ItemType Directory -Path (Join-Path $tools $lang) -Force | Out-Null
            Copy-Item -LiteralPath $mui -Destination (Join-Path $tools $lang)
        }
    }
}
@(
    '@echo off'
    'rem Run at Sandbox logon: make Notepad available, then open the PwManager folder'
    'rem Windows redirects notepad.exe to the Store app (IFEO), which the Sandbox does not have. Remove the redirect.'
    'reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" /f >nul 2>&1'
    'reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\UserChoice" /f >nul 2>&1'
    'assoc .txt=txtfile >nul 2>&1'
    'if exist "%windir%\System32\notepad.exe" ('
    '  ftype txtfile="%windir%\System32\notepad.exe" "%%1" >nul 2>&1'
    ') else ('
    '  setx PATH "C:\Tools" >nul'
    '  ftype txtfile="C:\Tools\notepad.exe" "%%1" >nul 2>&1'
    ')'
    "start `"`" explorer.exe $sandboxFolder"
) -join "`r`n" | Set-Content -LiteralPath (Join-Path $tools 'setup.cmd') -Encoding ASCII
@"
<Configuration>
  <MemoryInMB>2048</MemoryInMB>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($out))</HostFolder>
      <SandboxFolder>$sandboxFolder</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($tools))</HostFolder>
      <SandboxFolder>C:\Tools</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>C:\Tools\setup.cmd</Command>
  </LogonCommand>
</Configuration>
"@ | Set-Content -LiteralPath $wsb -Encoding UTF8

$count = @(Get-ChildItem -LiteralPath $out -Recurse -File).Count
Write-Host ''
Write-Host 'リリースを作りました。' -ForegroundColor Green
Write-Host "  フォルダー: $out（$count ファイル$(if ($IncludeTests) { '、テストを含む' })）"
Write-Host "  ZIP       : $zip"
Write-Host "  Sandbox   : $wsb をダブルクリック → デスクトップの PwManager で Install.bat を実行"
