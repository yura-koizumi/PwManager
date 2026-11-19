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
#>
[CmdletBinding()]
param(
    [switch]$IncludeTests,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ver = (Import-PowerShellDataFile (Join-Path $root 'PwManager\PwManager.psd1')).ModuleVersion
Write-Host "=== PwManager v$ver のリリースを作ります ===" -ForegroundColor Cyan

if (-not $SkipTests) {
    Write-Host '自動テストを実行します...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-Tests.ps1') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'テストが失敗したため、リリースを作りませんでした。' }
}

# 配布に含めるもの（ここに無いファイルは含めない。新しいファイルを足したときは、ここにも追加する）
$rootFiles   = 'Install.bat', 'Install.ps1', 'Uninstall.bat', 'Uninstall.ps1', 'README.md'
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
$allowed = '\.(ps1|psm1|psd1|bat|md)$|^config\.default\.json$'
$unexpected = @(Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Name -notmatch $allowed })
if ($unexpected) { throw "想定外のファイルが含まれています: $($unexpected.FullName -join ', ')" }

Compress-Archive -LiteralPath (Get-ChildItem -LiteralPath $out).FullName -DestinationPath $zip -CompressionLevel Optimal

# Windows Sandbox の設定（ホストのフォルダーは読み取り専用で割り当てるため、Sandbox から書き換えられない）
$wsb = Join-Path $releaseDir 'PwManager-Sandbox.wsb'
$sandboxFolder = 'C:\Users\WDAGUtilityAccount\Desktop\PwManager'
@"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($out))</HostFolder>
      <SandboxFolder>$sandboxFolder</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>explorer.exe $sandboxFolder</Command>
  </LogonCommand>
</Configuration>
"@ | Set-Content -LiteralPath $wsb -Encoding UTF8

$count = @(Get-ChildItem -LiteralPath $out -Recurse -File).Count
Write-Host ''
Write-Host 'リリースを作りました。' -ForegroundColor Green
Write-Host "  フォルダー: $out（$count ファイル$(if ($IncludeTests) { '、テストを含む' })）"
Write-Host "  ZIP       : $zip"
Write-Host "  Sandbox   : $wsb をダブルクリック → デスクトップの PwManager で Install.bat を実行"
