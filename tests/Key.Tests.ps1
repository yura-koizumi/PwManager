. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$keyFile = Join-Path $env:APPDATA 'PwManager\vaultkey.json'
$global:StorePw = $null
function global:Set-SecretStorePassword {
    param([securestring]$Password, [securestring]$NewPassword)
    if ((Plain $Password) -ne $global:StorePw) { throw 'Password is incorrect.' }
    $global:StorePw = Plain $NewPassword
}
function global:Unlock-SecretStore { param([securestring]$Password, $PasswordTimeout) $global:Unlocked = Plain $Password }
$store = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
New-Item -ItemType Directory -Path $store -Force | Out-Null
Set-Content -LiteralPath (Join-Path $store 'storefile') -Value 'encrypted'

Write-Host '回復キーの文字'
$bytes = [byte[]](0..19 | ForEach-Object { $_ * 13 })
$text = & $Pwm { param($b) ConvertTo-PwRecoveryText $b } $bytes
$back = { param($t) & $Pwm { param($t) ConvertFrom-PwRecoveryKey (S $t) } $t }
Check '4 文字ずつ 8 組'                          ($text -match '^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$')
Check '元のバイト列に戻る'                       (((& $back $text) -join ',') -eq ($bytes -join ','))
$loose = ($text.ToLower() -replace '-', ' ') -replace '0', 'o' -replace '1', 'l'
Check '小文字・空白区切り・O と 0、I/L と 1 の取り違えも受け付ける' (((& $back $loose) -join ',') -eq ($bytes -join ','))
Check '長さが違えば $null'                       ($null -eq (& $back $text.Substring(0, 30)) -and $null -eq (& $back ($text + 'A')))
Check '使わない文字（U）が入れば $null'          ($null -eq (& $back ('U' + $text.Substring(1))))

Write-Host '包む・取り出す'
$r = & $Pwm {
    $k1 = New-PwRandomBytes 32; $k2 = New-PwRandomBytes 32
    $data = [byte[]](1..40)
    $blob = Protect-PwBytes $k1 $data
    $tampered = [byte[]]$blob.Clone(); $tampered[20] = $tampered[20] -bxor 1
    @{ Ok = ((Unprotect-PwBytes $k1 $blob) -join ',') -eq ($data -join ','); Wrong = $null -eq (Unprotect-PwBytes $k2 $blob)
       Tampered = $null -eq (Unprotect-PwBytes $k1 $tampered); Random = -not ((Protect-PwBytes $k1 $data) -join ',').Equals($blob -join ',') }
}
Check '同じ鍵なら取り出せる'                 $r.Ok
Check '鍵が違えば取り出せない'               $r.Wrong
Check '1 ビットでも書き換えられたら取り出せない' $r.Tampered
Check '同じ内容でも毎回違う暗号文になる'     $r.Random

Write-Host '保管庫キーのファイル'
$set = New-TestKey 'master-password-1'
$global:StorePw = $set.StorePassword
$raw = Get-Content -LiteralPath $keyFile -Raw
$j = $raw | ConvertFrom-Json
Check 'SecretStore のパスワードは 32 バイトのランダム値（Base64 44 文字）' ($set.StorePassword.Length -eq 44 -and $set.StorePassword -ne (New-TestKey 'master-password-1').StorePassword)
$set = New-TestKey 'master-password-1'; $global:StorePw = $set.StorePassword
$raw = Get-Content -LiteralPath $keyFile -Raw; $j = $raw | ConvertFrom-Json
Check 'ファイルにマスターパスワードも保管庫キーもそのままは書かない' ($raw -notmatch 'master-password-1' -and $raw -notmatch [regex]::Escape($set.StorePassword))
$get = { param($p) & $Pwm { param($p) Plain (ConvertTo-PwStorePassword (Get-PwVaultKey (S $p))) } $p }
Check '正しいマスターパスワードで保管庫キーを取り出せる' ((& $get 'master-password-1') -eq $set.StorePassword)
$err = $null; try { & $get 'master-password-2' } catch { $err = $_ }
Check 'マスターパスワードが違えば InvalidCredentialException' ($err.Exception -is [Security.Authentication.InvalidCredentialException])

# 別の Windows ユーザー・PC で開こうとした状態（DPAPI で開けない）を、LocalMachine で包み直して再現する
$other = $j.PSObject.Copy()
$other.Device = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([byte[]](1..80), $null, 'LocalMachine'))
$other | ConvertTo-Json | Set-Content -LiteralPath $keyFile -Encoding UTF8
$err = $null; try { & $get 'master-password-1' } catch { $err = $_ }
Check '別のユーザー・PC のファイルなら、マスターパスワードが正しくても開けない' ($err -and $err.Exception.Message -match 'Windows ユーザーでは' -and -not ($err.Exception -is [Security.Authentication.InvalidCredentialException]))
Set-Content -LiteralPath $keyFile -Value $raw -Encoding UTF8 -NoNewline

$rec = { param($k) & $Pwm { param($k) Plain (ConvertTo-PwStorePassword (Unprotect-PwRecovery (Read-PwKeyFile).Recovery (S $k))) } $k }
Check '回復キーで保管庫キーを取り出せる'       ((& $rec $set.RecoveryKey) -eq $set.StorePassword)
$err = $null; try { & $rec ($set.RecoveryKey.Substring(0, 38) + $(if ($set.RecoveryKey[38] -eq 'A') { 'B' } else { 'A' })) } catch { $err = $_ }
Check '回復キーが 1 文字でも違えば取り出せない' ($err -and $err.Exception.Message -match '回復キーが違います')

Write-Host '回復キーのファイル（Show-PwRecoveryKey）'
$keyDir = Join-Path $TestRoot 'Desktop'; New-Item -ItemType Directory -Path $keyDir | Out-Null
& $Pwm { param($d) $script:RecoveryKeyDir = $d } $keyDir
$file = & $Pwm { param($t) Show-PwRecoveryKey $t } $text 6>$null
Check 'デスクトップ（の代わりのフォルダー）にテキストファイルを出す' ((Split-Path $file) -eq $keyDir -and (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -match [regex]::Escape($text))
Check 'PC から削除するよう書いておく' ((Get-Content -LiteralPath $file -Raw -Encoding UTF8) -match 'PC から削除')

Write-Host '保管庫キーと回復キーの作り直し（New-PwRecoveryKey）'
$file = New-PwRecoveryKey -MasterPassword (S 'master-password-1') -Confirm:$false 6>$null
$newKey = [regex]::Match((Get-Content -LiteralPath $file -Raw -Encoding UTF8), '([0-9A-Z]{4}-){7}[0-9A-Z]{4}').Value
Check '保管庫を新しい保管庫キーで暗号化し直す' ($global:StorePw -ne $set.StorePassword -and $global:StorePw -eq (& $get 'master-password-1') -and $global:Unlocked -eq $global:StorePw)
Check '新しい回復キーを表示し、それで開ける'   ($newKey -and $newKey -ne $set.RecoveryKey -and (& $rec $newKey) -eq $global:StorePw)
$err = $null; try { & $rec $set.RecoveryKey } catch { $err = $_ }
Check '古い回復キーでは開けなくなる'           ($null -ne $err)
Check '退避ファイルを残さない'                 (@(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'PwManager') -Filter 'pre-rekey-*').Count -eq 0)

$before = Get-Content -LiteralPath $keyFile -Raw
$beforePw = $global:StorePw
function global:Set-SecretStorePassword { throw 'disk full' }
$err = $null; try { New-PwRecoveryKey -MasterPassword (S 'master-password-1') -Confirm:$false 6>$null } catch { $err = $_ }
Check '暗号化し直せなかったら、キーのファイルを元に戻す' ($err -and (Get-Content -LiteralPath $keyFile -Raw) -eq $before -and (& $get 'master-password-1') -eq $beforePw)

Complete-Test
