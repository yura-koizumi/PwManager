# 3 回目のリリース前の確認（Sonnet による解析）で見つかった不具合が、再び起きないことを確かめる
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
$failPath = Join-Path $env:APPDATA 'PwManager\unlock.json'
$writeFails = { param([int]$Count, [datetime]$Last) @{ Count = $Count; Last = $Last.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } | ConvertTo-Json | Set-Content -LiteralPath $failPath -Encoding UTF8 }
$key = New-TestKey 'master-password-1'

Write-Host 'ロック解除の待ち時間'
& $writeFails 5 (Get-Date).AddYears(1)
Check '時計を戻して記録が未来になっても、待ち時間は上限（5 分）を超えない' ((& $Pwm { Get-PwUnlockRemaining }) -le 300)
& $writeFails 5 (Get-Date).AddMinutes(-10)
Check '待ち時間が過ぎていれば 0' ((& $Pwm { Get-PwUnlockRemaining }) -eq 0)
Set-Content -LiteralPath $failPath -Encoding UTF8 -Value '{ "Count": 3 }'
$err = $null; try { & $Pwm { Write-PwPriorFailures (Get-PwUnlockFailures) } 3>$null } catch { $err = $_ }
Check '記録に日時が無くても、知らせるところでエラーにならない' ($null -eq $err)

Write-Host '回復キーの作り直しでも、失敗の回数を戻して知らせる'
function global:Set-SecretStorePassword { param($Password, $NewPassword) }
function global:Unlock-SecretStore { param($Password, $PasswordTimeout) }
& $Pwm { param($d) $script:RecoveryKeyDir = $d } $TestRoot
& $writeFails 3 (Get-Date).AddMinutes(-1)
$out = @(New-PwRecoveryKey -MasterPassword (S 'master-password-1') -Confirm:$false 3>&1 6>$null)
Check 'それまでの失敗を知らせる' (@($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] -and "$_" -match '3 回失敗' }).Count -eq 1)
Check '回数を 0 に戻す' (-not (Test-Path -LiteralPath $failPath))

Write-Host 'CSV'
$cfgPath = Join-Path $env:APPDATA 'PwManager\config.json'
Set-Content -LiteralPath $cfgPath -Encoding UTF8 -Value '{ "Fields": [ { "Name": "Id", "Label": "ID" }, { "Name": "Pin", "Label": "暗証番号", "Sensitive": true } ] }'
[void](& $Pwm { Save-PwEntry -Title 'Bank' -Fields @{ Id = 'u1'; Pin = '4821' } -Password (S 'pw-b') })
$np = Join-Path $TestRoot 'np.csv'
Export-PwCsv -Path $np 3>$null
$text = [IO.File]::ReadAllText($np)
Check '-IncludePassword なしでは、秘密にする項目（Sensitive）も書き出さない' ($text -notmatch '4821' -and $text -notmatch 'Pin' -and $text -match 'u1')
$wp = Join-Path $TestRoot 'wp.csv'
Export-PwCsv -Path $wp -IncludePassword -Confirm:$false 3>$null
Check '-IncludePassword なら書き出す' ([IO.File]::ReadAllText($wp) -match '4821')
$out = @(Import-PwCsv -Path $np 3>&1 6>$null)
Check 'パスワードの列が無い CSV は、取り込まずに理由を知らせる' (@($out | Where-Object { "$_" -match 'パスワードの列がありません' }).Count -eq 1)
Remove-Item -LiteralPath $cfgPath

Write-Host 'コマンド'
$err = $null; try { Set-PwEntry 'Bank' -Generate -PromptPassword } catch { $err = $_ }
Check '-Generate と -PromptPassword は同時に指定できない' ($err -and $err.Exception.Message -match 'PromptPassword')
$err = $null; try { Restore-PwVault -Path (Join-Path $TestRoot 'missing.zip') -RecoveryKey (S $key.RecoveryKey) -NewMasterPassword (S 'master-password-2') -Confirm:$false } catch { $err = $_ }
Check '無いバックアップを指定したら、分かる言葉で知らせる' ($err -and $err.Exception.Message -match 'バックアップのファイルが見つかりません')
$err = $null; try { Get-PwHelp 'xyz' } catch { $err = $_ }
Check 'Get-PwHelp で当たるコマンドが無ければ、そう知らせる' ($err -and $err.Exception.Message -match 'ありません')
Check 'Get-PwEntry -IncludeTotalCount にも説明がある' ((Get-Help Get-PwEntry -Parameter IncludeTotalCount).Description.Text -match '件数')

Write-Host '回復キーの保存先（OneDrive で同期されるデスクトップを避ける）'
$env:OneDriveCommercial = 'C:\Users\u\OneDrive - Contoso'
$d = & $Pwm { Get-PwRecoveryKeyDir -Desktop 'C:\Users\u\Desktop' -Downloads 'C:\Users\u\Downloads' -UserProfile 'C:\Users\u' }
Check '同期されていなければ、デスクトップ' ($d.Path -eq 'C:\Users\u\Desktop' -and -not $d.Synced)
$d = & $Pwm { Get-PwRecoveryKeyDir -Desktop 'C:\Users\u\OneDrive - Contoso\デスクトップ' -Downloads 'C:\Users\u\Downloads' -UserProfile 'C:\Users\u' }
Check 'デスクトップが OneDrive の中なら、ダウンロード' ($d.Path -eq 'C:\Users\u\Downloads' -and $d.Synced)
$d = & $Pwm { Get-PwRecoveryKeyDir -Desktop 'C:\Users\u\OneDrive - Contoso\Desktop' -Downloads 'C:\Users\u\OneDrive - Contoso\Downloads' -UserProfile 'C:\Users\u' }
Check 'ダウンロードも同期されていれば、ユーザーのフォルダー' ($d.Path -eq 'C:\Users\u' -and $d.Synced)
$env:OneDriveCommercial = $null
Check '環境変数が無くても、パスに OneDrive を含めば同期とみなす' ((& $Pwm { Test-PwSyncedPath 'D:\OneDrive\Desktop' }) -and -not (& $Pwm { Test-PwSyncedPath 'C:\Users\u\Desktop' }))

Complete-Test
