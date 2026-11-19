. (Join-Path $PSScriptRoot 'TestHelper.ps1')

# SecretStore のパスワード変更・ロック解除を模擬する
$global:StorePassword = 'old-password-123'
$global:Calls = New-Object System.Collections.Generic.List[string]
function global:Plain([securestring]$s) { [pscredential]::new('x', $s).GetNetworkCredential().Password }
function global:Set-SecretStorePassword {
    param([securestring]$Password, [securestring]$NewPassword)
    if ((Plain $Password) -ne $global:StorePassword) { throw 'Password is incorrect.' }
    $global:StorePassword = Plain $NewPassword
    $global:Calls.Add('set')
}
function global:Unlock-SecretStore { param([securestring]$Password, $PasswordTimeout) $global:Calls.Add('unlock:' + (Plain $Password)) }
function global:S([string]$t) { ConvertTo-SecureString $t -AsPlainText -Force }

$store = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
New-Item -ItemType Directory -Path $store -Force | Out-Null
Set-Content -LiteralPath (Join-Path $store 'storefile') -Value 'encrypted'
$dataDir = Join-Path $env:APPDATA 'PwManager'
$audit = Join-Path $dataDir 'audit.log'

Write-Host '新しいパスワードの条件'
$rule = { param($n, $c, $cur) & $Pwm { param($n, $c, $cur) Test-PwMasterPasswordRule $n $c $cur } $n $c $cur }
Check '一致しなければ不可'         ($null -ne (& $rule (S 'new-password-123') (S 'new-password-124') $null))
Check '12 文字未満は不可'          ($null -ne (& $rule (S 'short') (S 'short') $null))
Check '今と同じものは不可'         ($null -ne (& $rule (S 'old-password-123') (S 'old-password-123') (S 'old-password-123')))
Check '大文字小文字の違いは別物'   ($null -ne (& $rule (S 'New-password-123') (S 'new-password-123') $null))
Check '条件を満たせば $null'       ($null -eq (& $rule (S 'new-password-123') (S 'new-password-123') (S 'old-password-123')))

Write-Host 'マスターパスワードの変更（Set-PwMasterPassword）'
$err = $null
try { Set-PwMasterPassword -Current (S 'wrong-password-1') -New (S 'new-password-123') -Confirm:$false } catch { $err = $_ }
Check '今のパスワードが違えば止まる' ($null -ne $err -and $err.Exception.Message -match '今のパスワード' -and $global:StorePassword -eq 'old-password-123')
$err = $null
try { Set-PwMasterPassword -Current (S 'old-password-123') -New (S 'short') -Confirm:$false } catch { $err = $_ }
Check '条件を満たさない新しいパスワードは止まる' ($null -ne $err -and $global:StorePassword -eq 'old-password-123')

Remove-Item -LiteralPath (Join-Path $dataDir 'pre-pwchange-*.zip') -ErrorAction SilentlyContinue
$global:Calls.Clear()
$r = Set-PwMasterPassword -Current (S 'old-password-123') -New (S 'new-password-123') -Confirm:$false
Check '新しいパスワードに変わる'           ($global:StorePassword -eq 'new-password-123')
Check '変更後、新しいパスワードで解除する' (($global:Calls -join ',') -eq 'set,unlock:new-password-123')
Check '変更前の保管庫を退避する'           ($r.SafetyCopy -and (Test-Path -LiteralPath $r.SafetyCopy) -and (Split-Path $r.SafetyCopy -Leaf) -like 'pre-pwchange-*.zip')
Check '監査ログに残す（パスワードは書かない）' ((Get-Content -LiteralPath $audit -Raw -Encoding UTF8) -match 'MASTERPW' -and (Get-Content -LiteralPath $audit -Raw) -notmatch 'password-123')

$r = Set-PwMasterPassword -Current (S 'new-password-123') -New (S 'third-password-1') -Confirm:$false

Write-Host '画面が開いているとき'
$mutex = New-Object System.Threading.Mutex($true, 'Local\PwManager-GUI')
try {
    $err = $null
    try { Set-PwMasterPassword -Current (S 'third-password-1') -New (S 'fourth-password') -Confirm:$false } catch { $err = $_ }
    Check '別のプロセスの画面が開いていれば止まる' ($null -ne $err -and $err.Exception.Message -match '画面が開いています' -and $global:StorePassword -eq 'third-password-1')
    $ok = & $Pwm {
        $script:PinnedConfig = Get-PwConfig
        try { [bool](Set-PwMasterPassword -Current (S 'third-password-1') -New (S 'fourth-password') -Confirm:$false) }
        finally { $script:PinnedConfig = $null }
    }
    Check 'この画面からの変更はできる' ($ok -and $global:StorePassword -eq 'fourth-password')
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }

Complete-Test
