# 実際のクリップボードを使う（終わったら元のテキストに戻す）
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
$CB = [System.Windows.Forms.Clipboard]
$saved = $CB::GetText()
try {
    Write-Host '画面からのコピー'
    $seq = & $Pwm { Set-PwClipboard -Text 'Secret-1' -Sensitive }
    Check 'コピー後のシーケンス番号を返す' ($seq -is [uint32] -and $seq -gt 0)
    Check 'そのまま残っていれば消す' ((& $Pwm { param($s) Clear-PwClipboardIfMatch $s } $seq) -and -not $CB::GetText())

    $seq = & $Pwm { Set-PwClipboard -Text 'Secret-2' -Sensitive }
    $CB::SetText('user-data')
    Check 'あとから別の物をコピーしていたら消さない' (-not (& $Pwm { param($s) Clear-PwClipboardIfMatch $s } $seq) -and $CB::GetText() -eq 'user-data')

    $seq = & $Pwm { Set-PwClipboard -Text 'Secret-3' -Sensitive }
    $CB::SetText('Secret-3')   # ほかのアプリが同じ内容を置き直した状態
    $h = & $Pwm { Get-PwTextHash (S 'Secret-3') }
    Check '同じ内容が置き直されても、ハッシュ併用なら消す' (& $Pwm { param($s, $h) Clear-PwClipboardIfMatch $s $h } $seq $h)

    Write-Host '内容のハッシュ（鍵付き）'
    $h1 = & $Pwm { Get-PwTextHash (S 'Secret-3') }
    $plainSha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('Secret-3')))
    Check '同じプロセスでは同じ内容から同じハッシュ' ($h1 -eq (& $Pwm { Get-PwTextHash (S 'Secret-3') }))
    Check '内容が違えば違うハッシュ'               ($h1 -ne (& $Pwm { Get-PwTextHash (S 'Secret-4') }))
    Check '鍵なしの SHA-256 とは違う（ハッシュから元の値を割り出せない）' ($h1 -ne $plainSha)

    Write-Host 'コンソールからのコピー（別プロセスで消去）'
    $global:captured = $null
    function global:Start-Process { param($FilePath, $WindowStyle, $ArgumentList) $global:captured = $ArgumentList }
    & $Pwm { Start-PwClipboardClearJob 12345 1 }
    Remove-Item function:\Start-Process
    $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($captured[-1]))
    Check 'コマンドラインには番号だけを渡す' ($cmd -match '-eq 12345' -and $cmd -notmatch 'SHA256|GetText')

    $seq = & $Pwm { Set-PwClipboard -Text 'Secret-5' -Sensitive }
    & $Pwm { param($s) Start-PwClipboardClearJob $s 1 } $seq
    Start-Sleep -Seconds 6
    Check '一定時間後に消す' (-not $CB::GetText())

    $seq = & $Pwm { Set-PwClipboard -Text 'Secret-6' -Sensitive }
    & $Pwm { param($s) Start-PwClipboardClearJob $s 1 } $seq
    $CB::SetText('user-data-2')
    Start-Sleep -Seconds 6
    Check '待つ間に別の物をコピーしたら消さない' ($CB::GetText() -eq 'user-data-2')
} finally {
    if ($saved) { $CB::SetText($saved) } else { $CB::Clear() }
}
Complete-Test
