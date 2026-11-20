. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$sec = S 'x'
function global:Add-Entry($n, $title, $id, $url) {
    $global:Store["pwm:$n"] = [pscustomobject]@{ Name = "pwm:$n"; Secret = $sec; Metadata = @{ Title = $title; Id = $id; Url = $url; Note = "メモ $n"; Created = '2026-01-01 00:00:00'; Updated = '2026-01-01 00:00:00' } }
}
Add-Entry 1 '社内ポータル' 'taro' 'https://portal.example.com'
Add-Entry 2 'Amazon' 'hanako' 'https://www.amazon.co.jp'
Add-Entry 3 'example 管理画面' 'admin' 'https://admin.test.jp'

Write-Host '検索（Get-PwEntry 検索語）'
$t = { param($q) @(Get-PwEntry $q | ForEach-Object Title) -join ',' }
Check 'タイトル・項目のどれかに含まれれば一致（大文字小文字は区別しない）' ((& $t 'EXAMPLE') -eq 'example 管理画面,社内ポータル')
Check '空白で区切ると、すべての語を含むものだけ'                     ((& $t 'example taro') -eq '社内ポータル')
Check '項目:文字 なら、その項目だけを探す'                          ((& $t 'url:example') -eq '社内ポータル')
Check '項目名は Label でも、大文字小文字が違ってもよい'             ((& $t 'URL:amazon') -eq 'Amazon' -and (& $t 'id:hana') -eq 'Amazon')
Check 'title:（タイトル:）でタイトルだけを探す'                     ((& $t 'title:example') -eq 'example 管理画面' -and (& $t 'タイトル:社内') -eq '社内ポータル')
Check '項目名に当たらなければ、ふつうの語として扱う（https:// など）' ((& $t 'https://www.amazon') -eq 'Amazon')
Check '備考（複数行の項目）も項目指定で探せる'                       ((& $t 'note:メモ 3') -eq 'example 管理画面')

Write-Host '表示する件数'
foreach ($n in 4..120) { Add-Entry $n ('サービス {0:D3}' -f $n) "u$n" '' }
$warn = $null
$r = @(Get-PwEntry -WarningVariable warn 3>$null)
Check '既定では 50 件まで'                               ($r.Count -eq 50)
Check '残りがあれば、件数と -All を知らせる'             ("$warn" -match '120 件のうち 1〜50 件目' -and "$warn" -match '-All')
$warn = $null
Check '-All なら全件、知らせない'                         (@(Get-PwEntry -All -WarningVariable warn 3>$null).Count -eq 120 -and -not $warn)
Check '-First で件数を指定（知らせない）'                 (@(Get-PwEntry -First 100 -WarningVariable warn 3>$null).Count -eq 100 -and -not $warn)
$page = @(Get-PwEntry -Skip 100 -First 50)
Check '-Skip でページ送り（最後のページは残りだけ）'     ($page.Count -eq 20 -and $page[0].Title -eq (@(Get-PwEntry -All)[100]).Title)
Check '絞り込んで 50 件以下なら、すべて返して知らせない' (@(Get-PwEntry ポータル -WarningVariable warn 3>$null).Count -eq 1 -and -not $warn)
$total = @(Get-PwEntry -First 1 -IncludeTotalCount)
Check '-IncludeTotalCount で全体の件数も返す'             ($total.Count -eq 2 -and "$($total[0])" -match '120')
$fmt = (Get-PwEntry -First 1 | Out-String -Width 200)
Check '表示は 1 件 1 行の表（Title・ID・URL・更新日時）' ($fmt -match 'Title\s+Id\s+Url\s+Updated' -and $fmt -notmatch 'Note')
Check 'パイプの先には全項目が渡る'                       ((Get-PwEntry ポータル).Note -eq 'メモ 1')

Write-Host 'ほかのコマンドからの検索は件数で区切らない'
Add-Entry 200 'ZZZ 最後のサービス' 'last' ''
$global:Copied = $null
& $Pwm { function script:Set-PwClipboard($Text, $Secret, [switch]$Sensitive) { $global:Copied = if ($Secret) { Plain $Secret } else { $Text }; 1 } ; function script:Start-PwClipboardClearJob { } }
Copy-PwField 'ZZZ 最後のサービス' Id 6>$null
Check '51 件目以降のエントリも Copy-PwField などで選べる' ($global:Copied -eq 'last')

Complete-Test
