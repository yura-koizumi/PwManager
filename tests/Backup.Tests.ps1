. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$store = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
$storeFile = Join-Path $store 'storefile'
New-Item -ItemType Directory -Path $store -Force | Out-Null
Set-Content -LiteralPath $storeFile -Value 'v1'
$dataDir = Join-Path $env:APPDATA 'PwManager'
$keyFile = Join-Path $dataDir 'vaultkey.json'
$key = New-TestKey 'master-password-1'
$opens = { param($p) try { (& $Pwm { param($p) Plain (ConvertTo-PwStorePassword (Get-PwVaultKey (S $p))) } $p) -eq $key.StorePassword } catch { $false } }

Write-Host 'バックアップ'
$dest = Join-Path $TestRoot 'backup'
$env:COMPUTERNAME = 'PC-01'
$zip = Backup-PwVault -Destination $dest
Check '保存先が無ければ作って、PC 名入りの ZIP を作る' ((Test-Path -LiteralPath $zip.FullName) -and $zip.Name -match '^PwManager-backup-PC-01-\d{8}-\d{6}\.zip$')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zf = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
$names = @($zf.Entries | ForEach-Object { $_.FullName -replace '/', '\' }); $zf.Dispose()
Check '保管庫と回復用の情報を入れる' ($names -contains 'secretmanagement\localstore\storefile' -and $names -contains 'recovery.json')
Check 'この PC 用の包み（vaultkey.json）は入れない' (-not ($names | Where-Object { $_ -match 'vaultkey' }))
$old = Join-Path $dest 'PwManager-backup-PC-01-20200101-000000.zip'
New-Item -ItemType File -Path $old | Out-Null
Start-Sleep -Milliseconds 1100
[void](Backup-PwVault -Destination $dest)
Check '古いバックアップは消さない（手で取るものなので）' ((Test-Path -LiteralPath $old) -and @(Get-ChildItem -LiteralPath $dest).Count -eq 3)
$mandatory = @((Get-Command Backup-PwVault).Parameters['Destination'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0
Check '保存先は必ず指定する（設定に保存先は持たない）' $mandatory

Write-Host '復元'
Set-Content -LiteralPath $storeFile -Value 'v2'
$restore = { param($rk, $pw) Restore-PwVault -Path $zip.FullName -RecoveryKey (S $rk) -NewMasterPassword (S $pw) -Confirm:$false 6>$null }
$gui = New-Object System.Threading.Mutex($true, 'Local\PwManager-GUI')   # 画面が開いている状態を再現
$err = $null
try { & $restore $key.RecoveryKey 'master-password-2' } catch { $err = $_ }
$gui.ReleaseMutex(); $gui.Dispose()
Check '画面が開いていれば復元しない' ($null -ne $err -and (Get-Content -LiteralPath $storeFile) -eq 'v2')
$err = $null
try { & $restore 'AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA' 'master-password-2' } catch { $err = $_ }
Check '回復キーが違えば、何も変えない' ($err.Exception.Message -match '回復キーが違います' -and (Get-Content -LiteralPath $storeFile) -eq 'v2' -and (& $opens 'master-password-1'))

# 新しい PC を再現（キーのファイルが無い）
Remove-Item -LiteralPath $keyFile
& $restore $key.RecoveryKey 'master-password-2'
Check '保管庫データが戻る' ((Get-Content -LiteralPath $storeFile) -eq 'v1')
Check '設定したマスターパスワードで、同じ保管庫キーを取り出せる' ((& $opens 'master-password-2') -and -not (& $opens 'master-password-1'))
Check '回復キーはそのまま使える' ((& $Pwm { param($k) Plain (ConvertTo-PwStorePassword (Unprotect-PwRecovery (Read-PwKeyFile).Recovery (S $k))) } $key.RecoveryKey) -eq $key.StorePassword)
Check '復元前の保管庫を退避する' (@(Get-ChildItem -LiteralPath $dataDir -Filter 'pre-restore-*.zip').Count -eq 1)
& $restore $key.RecoveryKey 'master-password-3'   # 続けてもう一度（退避ファイル名が重ならないこと）
Check '続けて復元しても、退避したファイルを上書きしない' (@(Get-ChildItem -LiteralPath $dataDir -Filter 'pre-restore-*.zip').Count -eq 2)

$legacy = Join-Path $TestRoot 'legacy.zip'
Compress-Archive -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement') -DestinationPath $legacy
$err = $null
try { Restore-PwVault -Path $legacy -RecoveryKey (S $key.RecoveryKey) -NewMasterPassword (S 'master-password-4') -Confirm:$false 6>$null } catch { $err = $_ }
Check '回復用の情報が無い ZIP は復元しない' ($err.Exception.Message -match 'recovery.json' -and (& $opens 'master-password-3'))

Complete-Test
