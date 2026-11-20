# Clipboard.ps1 - クリップボード
# （PwManager.psm1 から読み込まれる）

# クリップボードの内容がまだ自分のコピーかを確かめるためのハッシュの鍵。起動のたびに乱数で作り、どこにも保存しない。
# 鍵付き（HMAC）にしておくと、メモリーに残ったハッシュから元のパスワードを総当たりで割り出せない
$script:ClipHashKey = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($script:ClipHashKey); $rng.Dispose()
Remove-Variable rng

# パスワードは、関数やコマンドの引数に平文の文字列で渡さない（SecureString で渡す）。
# 会社などでモジュールのログ（イベント 4103）が有効だと、コマンドに渡した引数の値がイベントログに残るため。
# 平文に戻すのは、クリップボード・ファイル・画面に渡す直前だけで、そこでは .NET のメソッドを直接呼ぶ（ログに残らない）。

function ConvertFrom-PwSecret([securestring]$Secret) {
    # SecureString を平文に戻す（戻り値はログに残らない。受け取った側は .NET のメソッドにだけ渡すこと）
    if (-not $Secret) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-PwTextHash([securestring]$Secret) {
    # 同じプロセスの中でだけ比べられるハッシュ。作業用のバイト列は使い終わったらゼロで埋める
    $chars = Get-PwSecureChars $Secret
    $bytes = [Text.Encoding]::UTF8.GetBytes($chars)
    $hmac = [Security.Cryptography.HMACSHA256]::new($script:ClipHashKey)
    try { [BitConverter]::ToString($hmac.ComputeHash($bytes)) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length); [Array]::Clear($chars, 0, $chars.Length); $hmac.Dispose() }
}

$script:ClipSeqSignature = '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();'

function Get-PwClipboardSequence {
    # クリップボードが書き換わるたびに増える番号（Windows 標準 API）。内容を読まずに「変わったか」を判定できる
    if (-not ('PwManagerNative.Clip' -as [type])) {
        Add-Type -Namespace PwManagerNative -Name Clip -MemberDefinition $script:ClipSeqSignature
    }
    [PwManagerNative.Clip]::GetClipboardSequenceNumber()
}

function Set-PwClipboard([string]$Text, [securestring]$Secret, [switch]$Sensitive) {
    # コピーした直後のシーケンス番号を返す（消去時に、まだ自分のコピーが残っているかの判定に使う）。
    # パスワードは -Secret（SecureString）で渡す。ID などの項目は -Text
    Add-Type -AssemblyName System.Windows.Forms
    $cfg = Get-PwConfig
    $data = New-Object System.Windows.Forms.DataObject
    if ($Secret) { $Sensitive = $true; $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, (ConvertFrom-PwSecret $Secret)) }
    else { $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text) }
    if ($Sensitive -and $cfg.ExcludeFromClipboardHistory) {
        # Windows のクリップボード履歴(Win+V)・クラウド同期の対象外にする（Windows 標準の仕組み）
        foreach ($fmt in 'ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard') {
            $data.SetData($fmt, [System.IO.MemoryStream]::new([byte[]]@(0, 0, 0, 0)))
        }
    }
    [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
    Get-PwClipboardSequence
}

function Clear-PwClipboardIfMatch([uint32]$Sequence, [string]$Hash) {
    <# 自分がコピーした内容がまだ残っている場合だけ消す（後から別の物をコピーしていたら触らない）。
       シーケンス番号が変わっていなければ一致。-Hash（画面のプロセス内にだけ保持）を渡すと、
       ほかのアプリが同じ内容を置き直して番号だけ変わった場合も消す。 #>
    if (-not $Sequence -and -not $Hash) { return $false }
    Add-Type -AssemblyName System.Windows.Forms
    try {
        $match = $Sequence -and (Get-PwClipboardSequence) -eq $Sequence
        if (-not $match -and $Hash) {
            # 今のクリップボードの内容（パスワードかもしれない）は、SecureString にしてから渡す
            $cur = [System.Windows.Forms.Clipboard]::GetText()
            $match = $cur -and (Get-PwTextHash ([Net.NetworkCredential]::new('', $cur).SecurePassword)) -eq $Hash
            $cur = $null
        }
        if ($match) { [System.Windows.Forms.Clipboard]::Clear(); return $true }
    } catch { }
    $false
}

function Start-PwClipboardClearJob([uint32]$Sequence, [int]$Seconds) {
    <# コンソール用：別プロセスで一定時間後にクリップボードを消す。
       コマンドラインはほかのプロセスから読めるため、内容やハッシュではなくシーケンス番号だけを渡す。 #>
    $cmd = @"
Start-Sleep -Seconds $Seconds
try {
  Add-Type -Namespace PwManagerNative -Name Clip -MemberDefinition '$($script:ClipSeqSignature)'
  if ([PwManagerNative.Clip]::GetClipboardSequenceNumber() -eq $Sequence) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Clipboard]::Clear()
  }
} catch { }
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', $enc
}

function Copy-PwField {
    <#
    .SYNOPSIS
      エントリのパスワードや項目をクリップボードにコピーする。
    .DESCRIPTION
      パスワードは、設定の ClipboardClearSeconds（既定 30 秒）たつと消える（その間にほかのものをコピーしていれば消さない）。
    .PARAMETER Query
      対象の検索語（Get-PwEntry と同じ）。タイトルが完全に一致すればそれ、候補が複数なら選ぶ画面が出る。
    .PARAMETER Field
      コピーする項目（Name でも Label でもよい）。省略するとパスワード。
    .PARAMETER Previous
      変更前のパスワードをコピーする（パスワードを変えたとき、1 つ前のものだけ残している）。
    .EXAMPLE
      Copy-PwField '社内ポータル' -Previous   # 変更前のパスワードをコピー
    .EXAMPLE
      Copy-PwField '社内ポータル'          # パスワードをコピー
      Copy-PwField '社内ポータル' Id       # ID をコピー
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Query,
        [Parameter(Position = 1)][string]$Field = 'Password',
        [switch]$Previous
    )
    $cfg = Get-PwConfig
    $entry = Resolve-PwEntry $Query
    if (-not $entry) { return }

    if ($Previous) {
        $p = Get-PwPreviousPassword $entry.Name
        if (-not $p) { Write-Warning "「$($entry.Title)」には変更前のパスワードがありません。"; return }
        $secret = $p.Secret; $sensitive = $true; $label = "変更前のパスワード（$($p.Replaced) まで使用）"
    } elseif ($Field -in 'Password', 'PW', 'パスワード') {
        $secret = Get-PwPassword $entry.Name; $sensitive = $true; $label = 'パスワード'
    } else {
        $def = @($cfg.Fields | Where-Object { $_.Name -eq $Field -or $_.Label -eq $Field }) | Select-Object -First 1
        if (-not $def) { throw "項目 '$Field' は設定にありません。使える項目: Password, $(($cfg.Fields | ForEach-Object Name) -join ', ')" }
        $text = [string]$entry.($def.Name); $sensitive = [bool]$def.Sensitive; $label = $def.Label
        if (-not $text) { Write-Warning "「$($entry.Title)」の $label は空です。"; return }
    }

    # 秘密にする項目（Sensitive）も、パスワードと同じく SecureString で渡す（引数の値がログに残らないように）
    if (-not $secret -and $sensitive) { $secret = [Net.NetworkCredential]::new('', $text).SecurePassword; $text = $null }
    $seq = if ($secret) { Set-PwClipboard -Secret $secret } else { Set-PwClipboard -Text $text }
    $sec = [int]$cfg.ClipboardClearSeconds
    if ($sensitive -and $sec -gt 0) {
        Start-PwClipboardClearJob $seq $sec
        Write-Host "「$($entry.Title)」の $label をコピーしました（$sec 秒後に消去）" -ForegroundColor Green
    } else {
        Write-Host "「$($entry.Title)」の $label をコピーしました" -ForegroundColor Green
    }
}

