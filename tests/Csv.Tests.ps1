. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$dir = Join-Path $TestRoot 'csv'; New-Item -ItemType Directory -Path $dir | Out-Null
function global:Write-Csv([string]$Name, [string[]]$Lines) {
    $p = Join-Path $dir $Name
    [IO.File]::WriteAllLines($p, $Lines, (New-Object Text.UTF8Encoding $false))
    $p
}
function global:Reset-Store { $global:Store.Clear() }
function global:Get-One([string]$Title) {
    $e = @(Get-PwEntry -All | Where-Object Title -eq $Title)[0]
    if ($e) { $e | Add-Member -NotePropertyName Password -NotePropertyValue (& $Pwm { param($n) Get-PwPassword $n } $e.Name) -PassThru }
}

Write-Host 'ブラウザーやほかのツールの CSV を取り込む'
$cases = @(
    @{ Tool = 'Chrome / Edge'; Lines = @('name,url,username,password,note', 'Amazon,https://www.amazon.co.jp/,taro,pw-1,メモ1') }
    @{ Tool = 'Bitwarden'; Lines = @('folder,favorite,type,name,notes,reprompt,login_uri,login_username,login_password', ',,login,Amazon,メモ1,0,https://www.amazon.co.jp/,taro,pw-1') }
    @{ Tool = '1Password'; Lines = @('Title,Url,Username,Password,Favorite,Archived,Notes', 'Amazon,https://www.amazon.co.jp/,taro,pw-1,false,false,メモ1') }
    @{ Tool = 'KeePass'; Lines = @('"Account","Login Name","Password","Web Site","Comments"', '"Amazon","taro","pw-1","https://www.amazon.co.jp/","メモ1"') }
)
foreach ($c in $cases) {
    Reset-Store
    Import-PwCsv -Path (Write-Csv 'in.csv' $c.Lines) 6>$null 3>$null
    $e = Get-One 'Amazon'
    Check "$($c.Tool): タイトル・ID・URL・備考・パスワードを取り込む" ($e -and $e.Id -eq 'taro' -and $e.Url -eq 'https://www.amazon.co.jp/' -and $e.Note -eq 'メモ1' -and $e.Password -eq 'pw-1')
}

Reset-Store
$ff = Write-Csv 'firefox.csv' @(
    '"url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"',
    '"https://www.example.com","taro","pw-1",,"https://www.example.com","{1}","1700000000000","1700000000000","1700000000000"')
Import-PwCsv -Path $ff 6>$null 3>$null
$e = Get-One 'example.com'
Check 'Firefox: タイトルの列が無いので、URL のドメイン名（www. を除く）をタイトルにする' ($e -and $e.Id -eq 'taro' -and $e.Password -eq 'pw-1')

Reset-Store
$bw = Write-Csv 'bw-note.csv' @('folder,favorite,type,name,notes,reprompt,login_uri,login_username,login_password', ',,note,秘密のメモ,本文,0,,,')
Import-PwCsv -Path $bw 6>$null 3>$null
Check 'パスワードが空の行（Bitwarden のメモなど）は取り込まない' (@(Get-PwEntry -All).Count -eq 0)

$totp = Write-Csv 'bw-totp.csv' @('name,login_username,login_password,login_totp', 'GitHub,taro,pw-1,JBSWY3DPEHPK3PXP')
$err = $null; try { Import-PwCsv -Path $totp 6>$null 3>$null } catch { $err = $_ }
Check '2 段階認証の鍵など、入れる先の無い列があれば止める（取りこぼさない）' ($err -and $err.Exception.Message -match 'login_totp' -and @(Get-PwEntry -All).Count -eq 0)
Import-PwCsv -Path $totp -IgnoreUnknownColumns 6>$null 3>$null
Check '-IgnoreUnknownColumns なら、その列を無視して取り込む' ((Get-One 'GitHub').Id -eq 'taro')

Write-Host 'Chrome 形式で書き出す'
Reset-Store
[void](& $Pwm { Save-PwEntry -Title 'Amazon' -Fields @{ Id = 'taro'; Url = 'https://www.amazon.co.jp/'; Note = "- 箇条書きのメモ`n2 行目" } -Password (S 'pw,"1"') })
$out = Join-Path $dir 'chrome-out.csv'
Export-PwCsv -Path $out -Format Chrome -Confirm:$false 3>$null
$bytes = [IO.File]::ReadAllBytes($out)
Check 'BOM なしの UTF-8（ブラウザーが列名を読み違えないように）' (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB))
$r = @(Import-Csv -LiteralPath $out)
Check '列は name,url,username,password,note' ((($r[0].PSObject.Properties.Name) -join ',') -eq 'name,url,username,password,note')
Check '値は書き換えない（- で始まる備考に '' を付けない、カンマ・引用符・改行もそのまま）' ($r[0].note -eq "- 箇条書きのメモ`n2 行目" -and $r[0].password -eq 'pw,"1"' -and $r[0].username -eq 'taro')
Reset-Store
Import-PwCsv -Path $out 6>$null 3>$null
$e = Get-One 'Amazon'
Check '書き出したものを取り込み直すと、元どおりになる' ($e.Password -eq 'pw,"1"' -and $e.Note -eq "- 箇条書きのメモ`n2 行目" -and $e.Url -eq 'https://www.amazon.co.jp/')

$err = $null
try { Export-PwCsv -Path (Join-Path $dir 'x.csv') -Format Chrome -WhatIf 3>$null } catch { $err = $_ }
Check 'Chrome 形式は常にパスワードを含むので、確認を求める（-WhatIf なら書き出さない）' (-not (Test-Path -LiteralPath (Join-Path $dir 'x.csv')))

Complete-Test
