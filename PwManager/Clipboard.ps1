# Clipboard.ps1 - クリップボード
# （PwManager.psm1 から読み込まれる）


function Get-PwTextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
    finally { $sha.Dispose() }
}

$script:ClipSeqSignature = '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();'

function Get-PwClipboardSequence {
    # クリップボードが書き換わるたびに増える番号（Windows 標準 API）。内容を読まずに「変わったか」を判定できる
    if (-not ('PwManagerNative.Clip' -as [type])) {
        Add-Type -Namespace PwManagerNative -Name Clip -MemberDefinition $script:ClipSeqSignature
    }
    [PwManagerNative.Clip]::GetClipboardSequenceNumber()
}

function Set-PwClipboard([string]$Text, [switch]$Sensitive) {
    # コピーした直後のシーケンス番号を返す（消去時に、まだ自分のコピーが残っているかの判定に使う）
    Add-Type -AssemblyName System.Windows.Forms
    $cfg = Get-PwConfig
    $data = New-Object System.Windows.Forms.DataObject
    $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text)
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
            $cur = [System.Windows.Forms.Clipboard]::GetText()
            $match = $cur -and (Get-PwTextHash $cur) -eq $Hash
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
      コンソールからエントリの項目をコピーする。
    .EXAMPLE
      Copy-PwField 社内ポータル            # パスワードをコピー
      Copy-PwField 社内ポータル Id         # ID をコピー
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Query,
        [Parameter(Position = 1)][string]$Field = 'Password'
    )
    $cfg = Get-PwConfig
    $hits = @(Get-PwEntry -Filter $Query)
    $exact = @($hits | Where-Object { $_.Title -eq $Query })
    if ($exact.Count -eq 1) { $hits = $exact }
    if ($hits.Count -eq 0) { throw "「$Query」に一致するエントリはありません。" }
    $entry = if ($hits.Count -eq 1) { $hits[0] } else {
        $hits | Out-GridView -Title '対象を選んで [OK] を押してください' -OutputMode Single
    }
    if (-not $entry) { return }

    if ($Field -in 'Password', 'PW', 'パスワード') {
        $text = Get-PwPassword $entry.Name; $sensitive = $true; $label = 'パスワード'
    } else {
        $def = @($cfg.Fields | Where-Object { $_.Name -eq $Field -or $_.Label -eq $Field }) | Select-Object -First 1
        if (-not $def) { throw "項目 '$Field' は設定にありません。使える項目: Password, $(($cfg.Fields | ForEach-Object Name) -join ', ')" }
        $text = [string]$entry.($def.Name); $sensitive = [bool]$def.Sensitive; $label = $def.Label
        if (-not $text) { Write-Warning "「$($entry.Title)」の $label は空です。"; return }
    }

    $seq = Set-PwClipboard -Text $text -Sensitive:$sensitive
    $sec = [int]$cfg.ClipboardClearSeconds
    if ($sensitive -and $sec -gt 0) {
        Start-PwClipboardClearJob $seq $sec
        Write-Host "「$($entry.Title)」の $label をコピーしました（$sec 秒後に消去）" -ForegroundColor Green
    } else {
        Write-Host "「$($entry.Title)」の $label をコピーしました" -ForegroundColor Green
    }
}

