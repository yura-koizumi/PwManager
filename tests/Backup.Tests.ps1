. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$store = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
$storeFile = Join-Path $store 'storefile'
New-Item -ItemType Directory -Path $store -Force | Out-Null
Set-Content -LiteralPath $storeFile -Value 'v1'

Write-Host 'バックアップ'
$dest = Join-Path $TestRoot 'backup'
$env:COMPUTERNAME = 'PC-01'
$zip = Backup-PwVault -Destination $dest
Check '保存先が無ければ作って、PC 名入りの ZIP を作る' ((Test-Path -LiteralPath $zip.FullName) -and $zip.Name -match '^PwManager-backup-PC-01-\d{8}-\d{6}\.zip$')
$old = Join-Path $dest 'PwManager-backup-PC-01-20200101-000000.zip'
New-Item -ItemType File -Path $old | Out-Null
Start-Sleep -Milliseconds 1100
[void](Backup-PwVault -Destination $dest)
Check '古いバックアップは消さない（手で取るものなので）' ((Test-Path -LiteralPath $old) -and @(Get-ChildItem -LiteralPath $dest).Count -eq 3)
$err = $null

$mandatory = @((Get-Command Backup-PwVault).Parameters['Destination'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0
Check '保存先は必ず指定する（設定に保存先は持たない）' $mandatory

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
