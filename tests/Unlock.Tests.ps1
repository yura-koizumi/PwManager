. (Join-Path $PSScriptRoot 'TestHelper.ps1')

# 保管庫キーをマスターパスワード 'right-password' で作り、SecretStore は渡された保管庫キーだけを受け付ける
$global:UnlockCalls = 0
$global:Key = New-TestKey 'right-password'
function global:Unlock-SecretStore {
    param([securestring]$Password, $PasswordTimeout)
    $global:UnlockCalls++
    if ((Plain $Password) -ne $global:Key.StorePassword) { throw 'Password is incorrect.' }
}
$failFile = Join-Path $env:APPDATA 'PwManager\unlock.json'
function global:Try-Unlock([string]$pw) { try { & $Pwm { param($p) Invoke-PwUnlock (S $p) } $pw; 'ok' } catch { $_.Exception.Message } }
function global:Set-LastFailure([int]$SecondsAgo) {
    $j = Get-Content -LiteralPath $failFile -Raw | ConvertFrom-Json
    @{ Count = $j.Count; Last = (Get-Date).AddSeconds(-$SecondsAgo).ToString('yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json | Set-Content -LiteralPath $failFile -Encoding UTF8
}

Write-Host '待ち時間'
$waits = @(foreach ($n in 1..12) { & $Pwm { param($n) Get-PwUnlockWait $n } $n })
Check '4 回目までは待たない'                 (($waits[0..3] | Where-Object { $_ -ne 0 }).Count -eq 0)
Check '5 回目から 5 秒、倍々に延びる'        (($waits[4..8] -join ',') -eq '5,10,20,40,80')
Check '上限は 5 分'                          ($waits[11] -eq 300 -and ($waits | Measure-Object -Maximum).Maximum -eq 300)

Write-Host '続けて失敗したとき'
foreach ($i in 1..4) { [void](Try-Unlock 'wrong') }
Check '4 回までなら、すぐに次を試せる'       ((& $Pwm { Get-PwUnlockRemaining }) -eq 0 -and (& $Pwm { (Get-PwUnlockFailures).Count }) -eq 4)
[void](Try-Unlock 'wrong')
$left = & $Pwm { Get-PwUnlockRemaining }
Check '5 回目の失敗のあとは待ち時間がある'   ($left -ge 4 -and $left -le 5)
$calls = $global:UnlockCalls
$msg = Try-Unlock 'right-password'
Check '待ち時間中は、正しいパスワードでも試さない' ($msg -match '秒待って' -and $global:UnlockCalls -eq $calls)
Check '待ち時間中に試しても、回数は増えない' ((& $Pwm { (Get-PwUnlockFailures).Count }) -eq 5)

Write-Host '待ち時間が過ぎたあと'
Set-LastFailure 6
$before = & $Pwm { Invoke-PwUnlock (S 'right-password') }
Check '正しいパスワードで開ける'             ($global:UnlockCalls -eq $calls + 1)
Check 'それまでの失敗の回数と日時を返す'     ($before.Count -eq 5 -and $before.Last -is [datetime])
Check '開けたら回数を 0 に戻す'              (-not (Test-Path -LiteralPath $failFile) -and (& $Pwm { (Get-PwUnlockFailures).Count }) -eq 0)
Check '失敗がなければ 0 回を返す'            ((& $Pwm { Invoke-PwUnlock (S 'right-password') }).Count -eq 0)

Write-Host 'そのほか'
'{ 壊れた内容' | Set-Content -LiteralPath $failFile -Encoding UTF8
Check '記録が壊れていても、0 回として扱う'   ((& $Pwm { (Get-PwUnlockFailures).Count }) -eq 0 -and (Try-Unlock 'right-password') -eq 'ok')
[void](Try-Unlock 'wrong-secret-xyz')
$audit = Get-Content -LiteralPath (Join-Path $env:APPDATA 'PwManager\audit.log') -Raw -Encoding UTF8
Check '失敗を監査ログに残す（入力した値は書かない）' ($audit -match 'UNLOCK-FAIL' -and $audit -notmatch 'wrong-secret-xyz' -and $audit -notmatch 'right-password')
Check '違うときは「マスターパスワードが違います」' ((Try-Unlock 'wrong') -match 'マスターパスワードが違います')
[void](Try-Unlock 'right-password')
$keyFile = Join-Path $env:APPDATA 'PwManager\vaultkey.json'
Rename-Item -LiteralPath $keyFile -NewName 'vaultkey.bak'
$msg = Try-Unlock 'right-password'
Rename-Item -LiteralPath (Join-Path $env:APPDATA 'PwManager\vaultkey.bak') -NewName 'vaultkey.json'
Check 'キーのファイルが無いときは理由を示し、失敗の回数には数えない' ($msg -match '保管庫キーのファイルがありません' -and (& $Pwm { (Get-PwUnlockFailures).Count }) -eq 0)

Write-Host 'コマンドから使うとき（ロックされていれば尋ねて開く）'
$global:Locked = $true
function global:Get-SecretInfo { param($Vault, $Name) if ($global:Locked) { throw 'A valid password is required to access the Microsoft.PowerShell.SecretStore vault. Use the Unlock-SecretStore cmdlet.' } }
$global:Answers = [System.Collections.Queue]::new(@('wrong-1', 'right-password'))
function global:Read-Host { param($Prompt, [switch]$AsSecureString) S $global:Answers.Dequeue() }
$global:OrigUnlock = (Get-Command Unlock-SecretStore).ScriptBlock
function global:Unlock-SecretStore { param([securestring]$Password, $PasswordTimeout) & $global:OrigUnlock -Password $Password; $global:Locked = $false }
$err = $null
try { [void](Get-PwEntry 3>$null) } catch { $err = $_ }
Check '間違えても尋ね直し、正しいマスターパスワードで開いて続ける' ($null -eq $err -and -not $global:Locked -and $global:Answers.Count -eq 0)
$global:Locked = $true
$global:Answers = [System.Collections.Queue]::new(@('wrong-1', 'wrong-2', 'wrong-3', 'right-password'))
$err = $null
try { [void](Get-PwEntry 3>$null) } catch { $err = $_ }
Check '3 回続けて違えば止まる'                ($null -ne $err -and $global:Answers.Count -eq 1)
$global:Locked = $true
$err = $null
try { & $Pwm { $script:PinnedConfig = Get-PwConfig; try { Get-PwEntry } finally { $script:PinnedConfig = $null } } } catch { $err = $_ }
Check '画面の表示中は尋ねない（画面側で解除の画面を出す）' ($null -ne $err -and $global:Answers.Count -eq 1)
Remove-Item Function:\global:Read-Host

Complete-Test
