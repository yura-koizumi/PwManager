. (Join-Path $PSScriptRoot 'TestHelper.ps1')

# マスターパスワードの変更は、保管庫キーを包み直すだけ（SecretStore のパスワードは変えない）
$global:Calls = New-Object System.Collections.Generic.List[string]
function global:Set-SecretStorePassword { $global:Calls.Add('set-store') }
function global:Unlock-SecretStore { param([securestring]$Password, $PasswordTimeout) $global:Calls.Add('unlock:' + (Plain $Password)) }
$key = New-TestKey 'old-password-123'
$dataDir = Join-Path $env:APPDATA 'PwManager'
$audit = Join-Path $dataDir 'audit.log'
$vaultKey = { param($p) & $Pwm { param($p) Plain (ConvertTo-PwStorePassword (Get-PwVaultKey (S $p))) } $p }
$opens = { param($p) try { (& $vaultKey $p) -eq $key.StorePassword } catch { $false } }

Write-Host '新しいパスワードの条件'
$rule = { param($n, $c, $cur) & $Pwm { param($n, $c, $cur) Test-PwMasterPasswordRule $n $c $cur } $n $c $cur }
Check '一致しなければ不可'         ($null -ne (& $rule (S 'new-password-123') (S 'new-password-124') $null))
Check '12 文字未満は不可'          ($null -ne (& $rule (S 'short') (S 'short') $null))
Check '今と同じものは不可'         ($null -ne (& $rule (S 'old-password-123') (S 'old-password-123') (S 'old-password-123')))
Check '大文字小文字の違いは別物'   ($null -ne (& $rule (S 'New-password-123') (S 'new-password-123') $null))
Check '条件を満たせば $null'       ($null -eq (& $rule (S 'new-password-123') (S 'new-password-123') (S 'old-password-123')))

Write-Host '平文の文字列を作らない比較（Test-PwSecureStringEqual）'
$eq = { param($a, $b) & $Pwm { param($a, $b) Test-PwSecureStringEqual $a $b } $a $b }
Check '同じなら一致'                   (& $eq (S 'abc-DEF-123!') (S 'abc-DEF-123!'))
Check '大文字小文字が違えば不一致'     (-not (& $eq (S 'abc') (S 'abC')))
Check '長さが違えば不一致'             (-not (& $eq (S 'abc') (S 'abcd')))
Check '最後の 1 文字だけ違っても不一致' (-not (& $eq (S 'password-1234') (S 'password-1235')))
Check '日本語・絵文字も比べられる'     ((& $eq (S 'パスワード🔑です') (S 'パスワード🔑です')) -and -not (& $eq (S 'パスワード🔑です') (S 'パスワード🔒です')))
$empty1 = New-Object System.Security.SecureString; $empty2 = New-Object System.Security.SecureString
Check '空どうしは一致、空と空でないものは不一致' ((& $eq $empty1 $empty2) -and -not (& $eq $empty1 (S 'a')))

Write-Host 'マスターパスワードの変更（Set-PwMasterPassword）'
$err = $null
try { Set-PwMasterPassword -Current (S 'wrong-password-1') -New (S 'new-password-123') -Confirm:$false } catch { $err = $_ }
Check '今のパスワードが違えば止まる' ($null -ne $err -and $err.Exception.Message -match 'マスターパスワードが違います' -and (& $opens 'old-password-123'))
$err = $null
try { Set-PwMasterPassword -Current (S 'old-password-123') -New (S 'short') -Confirm:$false } catch { $err = $_ }
Check '条件を満たさない新しいパスワードは止まる' ($null -ne $err -and (& $opens 'old-password-123'))

$global:Calls.Clear()
$recBefore = (Get-Content -LiteralPath (Join-Path $dataDir 'vaultkey.json') -Raw | ConvertFrom-Json).Recovery | ConvertTo-Json
$r = Set-PwMasterPassword -Current (S 'old-password-123') -New (S 'new-password-123') -Confirm:$false
Check '新しいパスワードで開け、古いパスワードでは開けなくなる' ($r -and (& $opens 'new-password-123') -and -not (& $opens 'old-password-123'))
Check '保管庫は暗号化し直さず（保管庫キーは同じ）、そのまま開く' (($global:Calls -join ',') -eq "unlock:$($key.StorePassword)")
Check '回復用の包みは変えない（バックアップはそのまま使える）' ($recBefore -eq ((Get-Content -LiteralPath (Join-Path $dataDir 'vaultkey.json') -Raw | ConvertFrom-Json).Recovery | ConvertTo-Json))
Check '一時ファイルを作らない' (@(Get-ChildItem -LiteralPath $dataDir -Filter '*.zip').Count -eq 0)
Check '監査ログに残す（パスワードは書かない）' ((Get-Content -LiteralPath $audit -Raw -Encoding UTF8) -match 'MASTERPW' -and (Get-Content -LiteralPath $audit -Raw) -notmatch 'password-123')

Write-Host 'マスターパスワードを忘れたとき（-UseRecoveryKey）'
$err = $null
try { Set-PwMasterPassword -UseRecoveryKey -RecoveryKey (S 'AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA') -New (S 'forgot-password-1') -Confirm:$false } catch { $err = $_ }
Check '回復キーが違えば止まる' ($null -ne $err -and (& $opens 'new-password-123'))
[void](Set-PwMasterPassword -UseRecoveryKey -RecoveryKey (S $key.RecoveryKey) -New (S 'forgot-password-1') -Confirm:$false)
Check '回復キーで、今のパスワードを使わずに変更できる' ((& $opens 'forgot-password-1') -and -not (& $opens 'new-password-123'))

Write-Host '画面が開いているとき'
$mutex = New-Object System.Threading.Mutex($true, 'Local\PwManager-GUI')
try {
    $err = $null
    try { Set-PwMasterPassword -Current (S 'forgot-password-1') -New (S 'fourth-password') -Confirm:$false } catch { $err = $_ }
    Check '別のプロセスの画面が開いていれば止まる' ($null -ne $err -and $err.Exception.Message -match '画面が開いています' -and (& $opens 'forgot-password-1'))
    $ok = & $Pwm {
        $script:PinnedConfig = Get-PwConfig
        try { [bool](Set-PwMasterPassword -Current (S 'forgot-password-1') -New (S 'fourth-password') -Confirm:$false) }
        finally { $script:PinnedConfig = $null }
    }
    Check 'この画面からの変更はできる' ($ok -and (& $opens 'fourth-password'))
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }

Complete-Test
