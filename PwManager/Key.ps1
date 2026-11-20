# Key.ps1 - 保管庫キー（マスターパスワード・回復キー・Windows ユーザーへの結び付け）
# （PwManager.psm1 から読み込まれる）
<#
  SecretStore は、ランダムな保管庫キー（32 バイト）をパスワードとして暗号化する。保管庫キーは次の 2 通りで包んで保存する。

    この PC 用  : マスターパスワード（PBKDF2）で包み、さらに Windows のユーザーに結び付けて（DPAPI）包む
                  → ファイルを持ち出されても、別の PC・別のユーザーでは総当たりを始められない
    回復用      : 回復キー（ランダム 160 ビット）で包む。バックアップの ZIP にはこれを入れる
                  → バックアップはマスターパスワードの強さに関係なく、総当たりでは破れない

  包む処理は AES-256-CBC + HMAC-SHA256（暗号化してから改ざん検知の値を付ける）。
  マスターパスワードや回復キーが違えば、改ざん検知の値が合わないので分かる。
#>

$script:KeyPath       = Join-Path $script:DataDir 'vaultkey.json'
$script:RecoveryKeyDir = $null     # 回復キーのファイルの保存先（$null ならデスクトップ。テストで切り替える）
$script:KdfIterations = 300000    # PBKDF2-SHA256 の回数（約 1 秒）。回数はキーのファイルに残すので、変えても既存のものは開ける
$script:DpapiEntropy  = [Text.Encoding]::UTF8.GetBytes('PwManager.VaultKey.v1')
$script:Base32        = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'   # 回復キーの文字（Crockford Base32: I L O U は使わない）
Add-Type -AssemblyName System.Security   # ProtectedData（DPAPI）。.NET 標準のアセンブリを読み込むだけ

function New-PwRandomBytes([int]$Count) {
    $b = New-Object byte[] $Count
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    , $b
}

function Clear-PwBytes { foreach ($b in $args) { if ($b) { [Array]::Clear($b, 0, $b.Length) } } }

function Get-PwSecureChars([securestring]$Secure) {
    # SecureString の中身を char[] で取り出す（文字列を作らない。使い終わったら Clear-PwBytes で消す）
    $c = New-Object char[] $Secure.Length
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::Copy($p, $c, 0, $c.Length) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
    , $c
}

function Get-PwHmac([byte[]]$Key, [byte[]]$Data) {
    $h = New-Object Security.Cryptography.HMACSHA256 (, $Key)
    try { , $h.ComputeHash($Data) } finally { $h.Dispose() }
}

function Split-PwKey([byte[]]$Master) {
    # 1 つの鍵から、暗号化用と改ざん検知用の鍵を作り分ける
    @{ Enc = (Get-PwHmac $Master ([Text.Encoding]::ASCII.GetBytes('enc'))); Mac = (Get-PwHmac $Master ([Text.Encoding]::ASCII.GetBytes('mac'))) }
}

function Protect-PwBytes([byte[]]$Key, [byte[]]$Data) {
    $k = Split-PwKey $Key
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $k.Enc; $aes.GenerateIV()
        $enc = $aes.CreateEncryptor().TransformFinalBlock($Data, 0, $Data.Length)
        $body = [byte[]]($aes.IV + $enc)
        , [byte[]]($body + (Get-PwHmac $k.Mac $body))
    } finally { $aes.Dispose(); Clear-PwBytes $k.Enc $k.Mac }
}

function Unprotect-PwBytes([byte[]]$Key, [byte[]]$Blob) {
    # 鍵が違う・壊れているときは $null
    if ($Blob.Length -lt 64) { return $null }
    $k = Split-PwKey $Key
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $body = [byte[]]$Blob[0..($Blob.Length - 33)]
        $mac = Get-PwHmac $k.Mac $body
        $diff = 0
        for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($mac[$i] -bxor $Blob[$Blob.Length - 32 + $i]) }   # 比べる時間を一定にする
        if ($diff -ne 0) { return $null }
        $aes.Key = $k.Enc; $aes.IV = [byte[]]$body[0..15]
        , $aes.CreateDecryptor().TransformFinalBlock($body, 16, $body.Length - 16)
    } finally { $aes.Dispose(); Clear-PwBytes $k.Enc $k.Mac }
}

function Get-PwPasswordKey([securestring]$Password, [byte[]]$Salt, [int]$Iterations) {
    $c = Get-PwSecureChars $Password
    $b = [Text.Encoding]::UTF8.GetBytes($c)
    try {
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($b, $Salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
        try { , $kdf.GetBytes(32) } finally { $kdf.Dispose() }
    } finally { Clear-PwBytes $c $b }
}

#region 回復キー

function ConvertTo-PwRecoveryText([byte[]]$Bytes) {
    # 20 バイト → 32 文字（4 文字ずつ - で区切る）
    $sb = New-Object Text.StringBuilder
    $acc = 0; $bits = 0
    foreach ($x in $Bytes) {
        $acc = (($acc -shl 8) -bor $x) -band 0xFFFF; $bits += 8
        while ($bits -ge 5) { $bits -= 5; [void]$sb.Append($script:Base32[($acc -shr $bits) -band 31]) }
    }
    ($sb.ToString() -split '(.{4})' | Where-Object { $_ }) -join '-'
}

function ConvertFrom-PwRecoveryKey([securestring]$Key) {
    # 入力された回復キーを 20 バイトに戻す。区切りや空白・小文字は無視し、O→0・I/L→1 と読み替える。形式が違えば $null
    $c = Get-PwSecureChars $Key
    $out = New-Object byte[] 20
    try {
        $n = 0; $acc = 0; $bits = 0
        foreach ($ch in $c) {
            $u = [char]::ToUpperInvariant($ch)
            if ($u -eq '-' -or [char]::IsWhiteSpace($u)) { continue }
            if ($u -eq 'O') { $u = '0' } elseif ($u -eq 'I' -or $u -eq 'L') { $u = '1' }
            $v = $script:Base32.IndexOf($u)
            if ($v -lt 0 -or $n -ge 20) { return $null }
            $acc = (($acc -shl 5) -bor $v) -band 0xFFFF; $bits += 5
            if ($bits -ge 8) { $bits -= 8; $out[$n] = ($acc -shr $bits) -band 0xFF; $n++ }
        }
        if ($n -ne 20) { return $null }
        , $out
    } finally { Clear-PwBytes $c }
}

function Protect-PwRecovery([byte[]]$VaultKey, [byte[]]$RecoveryBytes) {
    $salt = New-PwRandomBytes 16
    $k = Get-PwHmac $RecoveryBytes $salt    # 回復キーは十分ランダムなので、時間のかかる処理は要らない
    try { [pscustomobject]@{ Salt = [Convert]::ToBase64String($salt); Data = [Convert]::ToBase64String((Protect-PwBytes $k $VaultKey)) } }
    finally { Clear-PwBytes $k }
}

function Unprotect-PwRecovery($Recovery, [securestring]$RecoveryKey) {
    # 回復キーで保管庫キーを取り出す。回復キーが違えば例外
    $r = ConvertFrom-PwRecoveryKey $RecoveryKey
    if (-not $r) { throw '回復キーの形式が違います（4 文字ずつ 8 組、32 文字）。' }
    $k = Get-PwHmac $r ([Convert]::FromBase64String($Recovery.Salt))
    try { $v = Unprotect-PwBytes $k ([Convert]::FromBase64String($Recovery.Data)) }
    finally { Clear-PwBytes $r $k }
    if (-not $v) { throw '回復キーが違います。' }
    , $v
}

#endregion

#region 保管庫キーのファイル（%APPDATA%\PwManager\vaultkey.json）

function Read-PwKeyFile {
    if (-not (Test-Path -LiteralPath $script:KeyPath)) {
        throw "保管庫キーのファイルがありません: $($script:KeyPath)`nバックアップがあれば Restore-PwVault で復元してください。"
    }
    Read-PwJson $script:KeyPath
}

function Write-PwKeyFile([byte[]]$VaultKey, [securestring]$MasterPassword, $Recovery) {
    # この PC 用の包み（マスターパスワード + Windows ユーザー）を作り直して保存する。回復用はそのまま引き継ぐ
    $salt = New-PwRandomBytes 16
    $pk = Get-PwPasswordKey $MasterPassword $salt $script:KdfIterations
    try {
        $inner = Protect-PwBytes $pk $VaultKey
        $device = [Security.Cryptography.ProtectedData]::Protect($inner, $script:DpapiEntropy, 'CurrentUser')
    } finally { Clear-PwBytes $pk }
    $j = [ordered]@{
        Version    = 1
        Iterations = $script:KdfIterations
        Salt       = [Convert]::ToBase64String($salt)
        Device     = [Convert]::ToBase64String($device)
        Recovery   = $Recovery
    }
    Initialize-PwDataDir
    $tmp = "$($script:KeyPath).tmp"
    $j | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
    # 書きかけのファイルを残さない。すでにあれば File.Replace で一度に入れ替える（消してから置く間に止まっても、鍵を失わない）
    if (Test-Path -LiteralPath $script:KeyPath) { [IO.File]::Replace($tmp, $script:KeyPath, [NullString]::Value) }   # $null だと空文字になり、パスの誤りになる
    else { Move-Item -LiteralPath $tmp -Destination $script:KeyPath }
}

function Get-PwVaultKey([securestring]$MasterPassword) {
    # マスターパスワードで保管庫キー（byte[]）を取り出す。違えば例外（メッセージに「マスターパスワードが違います」）
    $j = Read-PwKeyFile
    try { $inner = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($j.Device), $script:DpapiEntropy, 'CurrentUser') }
    catch { throw "この Windows ユーザーでは保管庫を開けません（別の PC やユーザーで作られた保管庫です）。`nバックアップと回復キーで復元してください（Restore-PwVault）。" }
    $pk = Get-PwPasswordKey $MasterPassword ([Convert]::FromBase64String($j.Salt)) ([int]$j.Iterations)
    try { $v = Unprotect-PwBytes $pk $inner } finally { Clear-PwBytes $pk $inner }
    if (-not $v) { throw [Security.Authentication.InvalidCredentialException]::new('マスターパスワードが違います。') }
    , $v
}

function ConvertTo-PwStorePassword([byte[]]$VaultKey) {
    # SecretStore に渡すパスワード（保管庫キーの Base64）。文字列を作らずに SecureString にする
    $c = New-Object char[] 44
    [void][Convert]::ToBase64CharArray($VaultKey, 0, $VaultKey.Length, $c, 0)
    $s = New-Object System.Security.SecureString
    try { foreach ($ch in $c) { $s.AppendChar($ch) } } finally { Clear-PwBytes $c }
    $s.MakeReadOnly()
    $s
}

function New-PwVaultKeySet([securestring]$MasterPassword) {
    # 新しい保管庫キーと回復キーを作り、キーのファイルを保存する。@{ StorePassword; RecoveryKey（表示用の文字列） } を返す
    $vk = New-PwRandomBytes 32
    $rb = New-PwRandomBytes 20
    try {
        Write-PwKeyFile $vk $MasterPassword (Protect-PwRecovery $vk $rb)
        @{ StorePassword = (ConvertTo-PwStorePassword $vk); RecoveryKey = (ConvertTo-PwRecoveryText $rb) }
    } finally { Clear-PwBytes $vk $rb }
}

function Test-PwSyncedPath([string]$Path) {
    # OneDrive で同期されるフォルダーの中か（会社の PC では、デスクトップやドキュメントが OneDrive に移されていることが多い）
    if (-not $Path) { return $false }
    $p = $Path.TrimEnd('\') + '\'
    foreach ($root in $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) {
        if ($root -and $p.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $p -match '\\OneDrive( - [^\\]+)?\\'
}

function Get-PwRecoveryKeyDir {
    <# 回復キーのファイルを置くフォルダー。デスクトップが OneDrive などで同期されていれば、同期されない
       ダウンロード、それも同期されていればユーザーのフォルダー（C:\Users\<名前>）にする。
       回復キーがクラウドに上がると、バックアップの ZIP と一緒に手に入れた人に開かれてしまうため。
       @{ Path = フォルダー; Synced = デスクトップが同期されていて、別の場所にしたか } を返す。 #>
    param(
        [string]$Desktop = [Environment]::GetFolderPath('Desktop'),
        [string]$Downloads = $(try { (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch { '' }),
        [string]$UserProfile = $env:USERPROFILE
    )
    if (-not (Test-PwSyncedPath $Desktop)) { return @{ Path = $Desktop; Synced = $false } }
    if ($Downloads -and -not (Test-PwSyncedPath $Downloads)) { return @{ Path = $Downloads; Synced = $true } }
    @{ Path = $UserProfile; Synced = $true }
}

function Show-PwRecoveryKey($KeySet) {
    # 回復キー（New-PwVaultKeySet の RecoveryKey）を画面に表示し、デスクトップ（同期されていればダウンロードなど）のテキストファイルにも出す。
    # ファイルの場所を返す（書けなかったら $null）。
    # 保管庫はもう回復キーで作られているので、ファイルに書けなくても止めずに、画面の表示を必ず残す。
    # 回復キーは文字列で引数に渡さず、Write-Host・Set-Content も使わない（引数の値がログに残りうるため。Clipboard.ps1 の説明を参照）
    $Text = [string]$KeySet.RecoveryKey
    $Host.UI.WriteLine()
    $Host.UI.WriteLine([ConsoleColor]::Yellow, $Host.UI.RawUI.BackgroundColor, "  回復キー: $Text")
    $place = if ($script:RecoveryKeyDir) { @{ Path = $script:RecoveryKeyDir; Synced = $false } } else { Get-PwRecoveryKeyDir }
    $dir = $place.Path
    $path = Join-Path $dir ('PwManager-回復キー-{0}-{1}.txt' -f $env:COMPUTERNAME, (Get-PwNow 'yyyyMMdd-HHmmss'))
    $lines = @(
        'PwManager 回復キー'
        ''
        "    $Text"
        ''
        "作成: $(Get-PwNow 'yyyy/MM/dd HH:mm')  PC: $env:COMPUTERNAME  ユーザー: $env:USERNAME"
        ''
        '・バックアップから戻すとき（Restore-PwVault）と、マスターパスワードを忘れたとき（Set-PwMasterPassword -UseRecoveryKey）に使います。'
        '・印刷するか USB メモリーなどに移して、このファイルは PC から削除してください。'
        '  PC に残すと、保管庫と一緒に持ち出されたときに開かれてしまいます。バックアップの ZIP とも別の場所に保管してください。'
    )
    try { [IO.File]::WriteAllLines($path, [string[]]$lines, (New-Object Text.UTF8Encoding $true)) }
    catch {
        Write-Warning "回復キーをファイルに保存できませんでした（$($_.Exception.Message)）。上の回復キーを書き留めてください。"
        return $null
    }
    Write-Host "  保存先  : $path"
    if ($place.Synced) { Write-Host '  （デスクトップは OneDrive などで同期されているので、クラウドに上がらないよう、同期されないこの場所に保存しました）' -ForegroundColor Yellow }
    Write-Host '  印刷するか USB メモリーなどに移して、このファイルは PC から削除してください。'
    $path
}

function New-PwRecoveryKey {
    <#
    .SYNOPSIS
      保管庫キーと回復キーを作り直す（回復キーが漏れた心配があるとき）。
    .DESCRIPTION
      保管庫を新しい保管庫キーで暗号化し直し、新しい回復キーを表示する。
      それまでのバックアップは古い回復キーで開けるので、不要なら削除して取り直すこと。
      PwManager の画面を閉じてから実行する。新しい回復キーは、デスクトップのテキストファイルにも保存する。
    .PARAMETER MasterPassword
      マスターパスワード（SecureString）。省略すると入力を求める。
    .EXAMPLE
      New-PwRecoveryKey
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([securestring]$MasterPassword)
    Assert-PwGuiClosed
    if (-not $MasterPassword) { $MasterPassword = Read-Host 'マスターパスワード' -AsSecureString }
    $checked = Get-PwVaultKeyChecked $MasterPassword   # ロック解除と同じく、続けて間違えると待ち時間が延びる（Vault.ps1）
    $old = $checked.Key
    Write-PwPriorFailures $checked.Before   # 正しいマスターパスワードを確かめられたので、それまでの失敗を知らせて回数を戻す
    Reset-PwUnlockFailures $checked.Before
    if (-not $PSCmdlet.ShouldProcess('保管庫キーと回復キー', '作り直し')) { Clear-PwBytes $old; return }
    $oldPw = ConvertTo-PwStorePassword $old
    $oldFile = Get-Content -LiteralPath $script:KeyPath -Raw -Encoding UTF8
    $safety = Save-PwVaultSafetyCopy 'pre-rekey'   # 途中で失敗したときのため（成功したら消す）
    try {
        $set = New-PwVaultKeySet $MasterPassword
        Set-SecretStorePassword -Password $oldPw -NewPassword $set.StorePassword
    } catch {
        Set-Content -LiteralPath $script:KeyPath -Value $oldFile -Encoding UTF8 -NoNewline
        throw "作り直せませんでした（保管庫はそのままです）。退避ファイル: $safety`n$($_.Exception.Message)"
    } finally { Clear-PwBytes $old }
    # 保管庫はもう新しい鍵になっているので、このあとで失敗しても回復キーを失わないよう、先に表示する
    $file = Show-PwRecoveryKey $set
    if ($safety) { Remove-Item -LiteralPath $safety -Force -ErrorAction SilentlyContinue }
    Write-PwAudit 'REKEY' '保管庫キーと回復キーを作り直し'
    Unlock-PwVault $set.StorePassword
    $file
}

#endregion
