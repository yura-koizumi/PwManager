# テスト共通（各 *.Tests.ps1 の先頭で読み込む）
#   ・設定・保管庫の置き場所を一時フォルダーに切り替え、実際のデータには触れない
#   ・SecretManagement のコマンドをモックに置き換える（モジュールが入っていなくても動く）
$ErrorActionPreference = 'Stop'

$TestRoot = Join-Path $env:TEMP ('pwm-test-' + [guid]::NewGuid().ToString('N'))
$env:APPDATA      = Join-Path $TestRoot 'AppData'
$env:LOCALAPPDATA = Join-Path $TestRoot 'LocalAppData'
New-Item -ItemType Directory -Path (Join-Path $env:APPDATA 'PwManager'), $env:LOCALAPPDATA -Force | Out-Null

$global:Store = @{}
function global:Get-SecretVault      { [pscustomobject]@{ Name = 'PwVault'; IsDefault = $true } }
function global:Register-SecretVault { }
function global:Get-SecretInfo { param($Vault, $Name) @($global:Store.Values | Where-Object { $_.Name -like $Name }) }
function global:Set-SecretInfo { param($Vault, $Name, $Metadata) $global:Store[$Name].Metadata = $Metadata }
function global:Set-Secret     { param($Vault, $Name, $Secret, $Metadata) $global:Store[$Name] = [pscustomobject]@{ Name = $Name; Secret = $Secret; Metadata = $Metadata } }
function global:Remove-Secret  { param($Vault, $Name) $global:Store.Remove($Name) }
function global:Get-Secret {
    param($Vault, $Name, [switch]$AsPlainText)
    [pscredential]::new('x', $global:Store[$Name].Secret).GetNetworkCredential().Password
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Import-Module (Join-Path $PSScriptRoot '..\PwManager\PwManager.psd1') -Force
$Pwm = Get-Module PwManager   # 非公開の関数は & $Pwm { ... } で呼ぶ

$script:Failures = 0
function Check([string]$Label, [bool]$Ok) {
    if ($Ok) { Write-Host "  OK   $Label" } else { Write-Host "  FAIL $Label" -ForegroundColor Red; $script:Failures++ }
}
function Complete-Test {
    Remove-Module PwManager -Force
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit $script:Failures
}
