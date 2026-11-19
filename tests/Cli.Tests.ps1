. (Join-Path $PSScriptRoot 'TestHelper.ps1')

function global:Plain([securestring]$s) { [pscredential]::new('x', $s).GetNetworkCredential().Password }
function global:S([string]$t) { ConvertTo-SecureString $t -AsPlainText -Force }
function global:Meta([string]$Title) { ($global:Store.Values | Where-Object { $_.Metadata['Title'] -eq $Title }) }

Write-Host '登録（New-PwEntry）'
$e = New-PwEntry Amazon -Fields @{ ID = 'taro'; Url = 'https://www.amazon.co.jp' } -Password (S 'p@ss-1')
Check '登録したエントリを返す（パスワードは含まない）' ($e.Title -eq 'Amazon' -and $e.Id -eq 'taro' -and $e.Name -like 'pwm:*' -and -not $e.PSObject.Properties['Password'])
Check '項目は表示名（ID）でも名前（Url）でも指定できる' ((Meta 'Amazon').Metadata['Id'] -eq 'taro' -and (Meta 'Amazon').Metadata['Url'] -eq 'https://www.amazon.co.jp')
Check 'パスワードを保存する' ((Plain (Meta 'Amazon').Secret) -eq 'p@ss-1')
$g = New-PwEntry 'GitHub' -Generate 6>$null
$gp = Plain (Meta 'GitHub').Secret
Check '-Generate で設定どおりの長さのパスワードを作る' ($gp.Length -eq 20)
$err = $null; try { New-PwEntry X -Fields @{ Email = 'a' } -Password (S 'x') } catch { $err = $_ }
Check '設定に無い項目は登録しない' ($null -ne $err -and $err.Exception.Message -match 'Email' -and -not (Meta 'X'))
$err = $null; try { New-PwEntry Y -Password (S 'x') -Generate } catch { $err = $_ }
Check '-Password と -Generate は同時に使えない' ($null -ne $err -and -not (Meta 'Y'))

Write-Host '編集（Set-PwEntry）'
[void](Set-PwEntry Amazon -Fields @{ URL = 'https://www.amazon.com' })
$m = (Meta 'Amazon').Metadata
Check '指定した項目だけ変わる' ($m['Url'] -eq 'https://www.amazon.com' -and $m['Id'] -eq 'taro')
Check 'パスワードはそのまま' ((Plain (Meta 'Amazon').Secret) -eq 'p@ss-1')
[void](Set-PwEntry Amazon -Generate 6>$null)
Check '-Generate でパスワードを作り直す' ((Plain (Meta 'Amazon').Secret) -ne 'p@ss-1' -and (Plain (Meta 'Amazon').Secret).Length -eq 20)
[void](Get-PwEntry GitHub | Set-PwEntry -Title 'GitHub (仕事)')
Check 'パイプラインで渡したエントリのタイトルを変える' ((Meta 'GitHub (仕事)') -and -not (Meta 'GitHub') -and (Plain (Meta 'GitHub (仕事)').Secret) -eq $gp)
$warn = Set-PwEntry Amazon 3>&1
Check '変更内容が無ければ何もしない' ("$warn" -match '変更する内容がありません')
$err = $null; try { Set-PwEntry 'ありえない名前' -Title 'x' } catch { $err = $_ }
Check '一致するエントリが無ければ止まる' ($null -ne $err -and $err.Exception.Message -match '一致するエントリはありません')

Write-Host '削除（Remove-PwEntry）'
Remove-PwEntry Amazon -Confirm:$false
Check '検索語で削除する' (-not (Meta 'Amazon') -and $global:Store.Count -eq 1)
Get-PwEntry GitHub | Remove-PwEntry -Confirm:$false
Check 'パイプラインで渡したエントリを削除する' ($global:Store.Count -eq 0)
$audit = Get-Content -LiteralPath (Join-Path $env:APPDATA 'PwManager\audit.log') -Raw -Encoding UTF8
Check '監査ログに残す（パスワードもタイトルも書かない）' ($audit -notmatch 'Amazon' -and $audit -notmatch 'GitHub' -and $audit -match 'ADD' -and $audit -match 'DELETE' -and $audit -notmatch 'p@ss-1' -and $audit -notmatch [regex]::Escape($gp))

Write-Host '画面が開いているとき'
$mutex = New-Object System.Threading.Mutex($true, 'Local\PwManager-GUI')
try {
    $blocked = foreach ($cmd in { New-PwEntry Z -Password (S 'x') }, { Set-PwEntry Z -Title 'z' }, { Remove-PwEntry Z -Confirm:$false }) {
        $err = $null; try { & $cmd } catch { $err = $_ }
        $null -ne $err -and $err.Exception.Message -match '画面が開いています'
    }
    Check '登録・編集・削除はしない' ((@($blocked) -notcontains $false) -and $global:Store.Count -eq 0)
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }

Complete-Test
