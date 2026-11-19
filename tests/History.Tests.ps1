. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$save = { param($n, $pw) & $Pwm { param($n, $pw) Save-PwEntry -Name $n -Title 'サービス' -Password $(if ($pw) { S $pw }) } $n $pw }
$prev = { param($n) & $Pwm { param($n) Get-PwPreviousPassword $n } $n }
$name = & $Pwm { Save-PwEntry -Title 'サービス' -Fields @{ Id = 'taro' } -Password (S 'first-pw') }

Write-Host '変更前のパスワード'
Check '登録しただけでは、変更前のパスワードは無い'     ($null -eq (& $prev $name))
[void](& $save $name $null)
Check 'パスワード以外の更新では残さない'               ($null -eq (& $prev $name))
[void](& $save $name 'second-pw')
$p = & $prev $name
Check 'パスワードを変えたら、変更前のものを残す'       ($p.Text -eq 'first-pw' -and $p.Replaced -match '^\d{4}-\d\d-\d\d')
Check '今のパスワードは新しいもの'                     ((& $Pwm { param($n) Get-PwPassword $n } $name) -eq 'second-pw')
[void](& $save $name 'second-pw')
Check '同じパスワードを入れ直しても、変更前のものは消えない' ((& $prev $name).Text -eq 'first-pw')
[void](& $save $name 'third-pw')
Check '残すのは 1 つ前だけ'                            ((& $prev $name).Text -eq 'second-pw' -and @($global:Store.Keys | Where-Object { $_ -like 'pwm-prev:*' }).Count -eq 1)
Check '一覧には出ない'                                 (@(Get-PwEntry -All).Count -eq 1)

Write-Host 'コピー'
$global:Copied = $null
& $Pwm { function script:Set-PwClipboard($Text, [switch]$Sensitive) { $global:Copied = $Text; 1 }; function script:Start-PwClipboardClearJob { } }
Copy-PwField サービス -Previous 6>$null
Check 'Copy-PwField -Previous で変更前のパスワードをコピーする' ($global:Copied -eq 'second-pw')
$other = & $Pwm { Save-PwEntry -Title '別のサービス' -Password (S 'x-pw') }
$warn = $null
Copy-PwField 別のサービス -Previous -WarningVariable warn 3>$null 6>$null
Check '無いときは知らせる'                             ("$warn" -match '変更前のパスワードがありません')

Write-Host '削除'
Remove-PwEntry -Name $name -Confirm:$false
Check 'エントリを消すと、変更前のパスワードも消す'     (@($global:Store.Keys | Where-Object { $_ -like 'pwm-prev:*' }).Count -eq 0)

Complete-Test
