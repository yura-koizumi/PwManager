. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$store = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
$storeFile = Join-Path $store 'storefile'
New-Item -ItemType Directory -Path $store -Force | Out-Null
Set-Content -LiteralPath $storeFile -Value 'v1'
Set-Content -LiteralPath (Join-Path $env:APPDATA 'PwManager\config.json') -Value '{ "BackupKeep": 2 }' -Encoding UTF8

Write-Host 'バックアップの世代管理'
$dest = Join-Path $TestRoot 'backup'
New-Item -ItemType Directory -Path $dest | Out-Null
$env:COMPUTERNAME = 'PC-01'
$others = 'PwManager-backup-PC-01-B-20200101-000000.zip', 'PwManager-backup-OTHER-20200101-000000.zip'
foreach ($n in @('PwManager-backup-PC-01-20200101-000000.zip', 'PwManager-backup-PC-01-20200102-000000.zip') + $others) {
    (New-Item -ItemType File -Path (Join-Path $dest $n)).LastWriteTime = (Get-Date).AddDays(-30)
}
$zip = Backup-PwVault -Destination $dest
$names = @(Get-ChildItem -LiteralPath $dest | ForEach-Object Name)
Check 'この PC の分は BackupKeep 件だけ残す' (@($names -match '^PwManager-backup-PC-01-\d').Count -eq 2 -and $names -contains $zip.Name)
Check 'ほかの PC の分は、名前が似ていても消さない' ($names -contains $others[0] -and $names -contains $others[1])

Write-Host '復元'
Set-Content -LiteralPath $storeFile -Value 'v2'
$gui = New-Object System.Threading.Mutex($true, 'Local\PwManager-GUI')   # 画面が開いている状態を再現
$err = $null
try { Restore-PwVault -Path $zip.FullName -Confirm:$false } catch { $err = $_ }
$gui.ReleaseMutex(); $gui.Dispose()
Check '画面が開いていれば復元しない' ($null -ne $err -and (Get-Content -LiteralPath $storeFile) -eq 'v2')
Restore-PwVault -Path $zip.FullName -Confirm:$false 6>$null
Check '保管庫データが戻る' ((Get-Content -LiteralPath $storeFile) -eq 'v1')
Check '復元前の保管庫を退避する' (@(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'PwManager') -Filter 'pre-restore-*.zip').Count -eq 1)
Restore-PwVault -Path $zip.FullName -Confirm:$false 6>$null   # 続けてもう一度（退避ファイル名が重ならないこと）
Check '続けて復元しても、退避したファイルを上書きしない' (@(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'PwManager') -Filter 'pre-restore-*.zip').Count -eq 2)

Complete-Test
