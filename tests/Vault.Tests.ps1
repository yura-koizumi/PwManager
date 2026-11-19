. (Join-Path $PSScriptRoot 'TestHelper.ps1')

Write-Host '保存（Save-PwEntry）'
$global:pw = ConvertTo-SecureString 'p@ss' -AsPlainText -Force
$name = & $Pwm { Save-PwEntry -Title 'T' -Fields @{ Id = 'u1'; X = 'keep' } -Password $global:pw }
& $Pwm { param($n) Save-PwEntry -Name $n -Title 'T2' -Fields @{ Id = 'u2' } } $name | Out-Null
$md = $global:Store[$name].Metadata
Check '渡さなかった項目のデータは残る' ($md['X'] -eq 'keep')
Check '渡した項目とタイトルは更新される' ($md['Id'] -eq 'u2' -and $md['Title'] -eq 'T2')
$err = $null
try { & $Pwm { param($n) Save-PwEntry -Name $n -Title 'T' -Fields @{ Title = 'x' } } $name } catch { $err = $_ }
Check '予約語の項目名は拒否する' ($null -ne $err)

Write-Host '設定の固定（画面の表示中）'
& $Pwm { $script:PinnedConfig = @{ VaultName = 'Pinned' } }
Check '表示中は起動時の設定を返す' ((& $Pwm { Get-PwConfig }).VaultName -eq 'Pinned')
& $Pwm { $script:PinnedConfig = $null }
Check '閉じたあとはファイルから読む' ((& $Pwm { Get-PwConfig }).VaultName -eq 'PwVault')

Write-Host 'CSV の書き出し・取り込み'
$global:Store.Clear()
$global:pw = ConvertTo-SecureString '-pw=1' -AsPlainText -Force
& $Pwm { Save-PwEntry -Title '=1+1' -Fields @{ Id = '@user'; Note = 'plain' } -Password $global:pw } | Out-Null
$csv = Join-Path $TestRoot 'out.csv'
Export-PwCsv -Path $csv -IncludePassword -Confirm:$false 3>$null
$row = Import-Csv -LiteralPath $csv -Encoding UTF8
Check '数式になる値は先頭に '' を付ける' ($row.Title -eq "'=1+1" -and $row.Id -eq "'@user")
Check 'ふつうの値はそのまま' ($row.Note -eq 'plain')
Check 'パスワードは書き換えない' ($row.Password -eq '-pw=1')
$global:Store.Clear()
Import-PwCsv -Path $csv 3>$null 6>$null
$e = @(Get-PwEntry)[0]
Check '取り込むと元の値に戻る' ($e.Title -eq '=1+1' -and $e.Id -eq '@user')
Check 'パスワードも元のまま取り込む' ((& $Pwm { param($n) Get-PwPassword $n } $e.Name) -eq '-pw=1')

Write-Host '監査ログ'
& $Pwm { $script:AuditMaxBytes = 300 }
1..10 | ForEach-Object { & $Pwm { Write-PwAudit 'TEST' ('x' * 50) } }
$audit = Join-Path $env:APPDATA 'PwManager\audit.log'
Check '上限を超えると audit.old.log に移す' ((Test-Path ($audit -replace '\.log$', '.old.log')) -and (Get-Item $audit).Length -le 600)

Complete-Test
