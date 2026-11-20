# リリース前の確認（Sonnet による解析）で見つかった不具合が、再び起きないことを確かめる
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
$global:Copied = $null
& $Pwm { function script:Set-PwClipboard($Text, $Secret, [switch]$Sensitive) { $global:Copied = if ($Secret) { Plain $Secret } else { $Text }; 1 }; function script:Start-PwClipboardClearJob { } }

Write-Host '対象の指定（Copy-PwField・Set-PwEntry・Remove-PwEntry）'
[void](& $Pwm { Save-PwEntry -Title 'Id:123' -Fields @{ Id = 'x' } -Password (S 'pw-colon') })
[void](& $Pwm { Save-PwEntry -Title 'ＡＢＣ商事' -Fields @{ Id = 'abc' } -Password (S 'pw-width') })
Copy-PwField 'Id:123' 6>$null
Check '「項目:文字」に見えるタイトルも、タイトルそのままで指定できる' ($global:Copied -eq 'pw-colon')
$err = $null; try { Remove-PwEntry '   ' -Confirm:$false } catch { $err = $_ }
Check '空白だけの検索語では、何も消さない' ($err -and @(Get-PwEntry -All).Count -eq 2)
Check '全角半角・大文字小文字を区別せずに探す（画面の検索と同じ）' (@(Get-PwEntry 'abc商事').Count -eq 1)
[void](& $Pwm { Save-PwEntry -Title 'アイウ' -Password (S 'pw-kana') })
Check 'ひらがなカタカナを区別せずに探す' (@(Get-PwEntry 'あいう').Count -eq 1)

Write-Host '引数の誤り'
$err = $null; try { Set-PwEntry 'アイウ' -Password (New-Object System.Security.SecureString) } catch { $err = $_ }
Check '-Password が空なら、何も変えずに知らせる' ($err -and $err.Exception.Message -match '空')
$e = New-PwEntry 'フィールドなし' -Fields $null -Generate 6>$null
Check '-Fields $null でも登録できる' ($e.Title -eq 'フィールドなし')
$err = $null; try { New-PwPassword -Length 0 } catch { $err = $_ }
Check '-Length 0 は断る（既定の長さにしない）' ($null -ne $err)
$err = $null; try { New-PwPassword -SymbolChars 'abc' } catch { $err = $_ }
Check '-SymbolChars に記号が無ければ、黙って記号なしにせず知らせる' ($err -and $err.Exception.Message -match 'NoSymbols')

Write-Host 'Get-PwHelp'
$h = Get-PwHelp pwm
Check 'Get-PwHelp pwm で画面のコマンドの説明を出す（一覧では pwm と表示しているため）' ($h.Name -eq 'Show-PwManager')
$err = $null; try { Get-PwHelp '[' } catch { $err = $_ }
Check '[ などの記号を含む名前でも、ワイルドカードの誤りにならない' (-not $err -or $err.Exception.Message -match 'ありません|件あります')

Write-Host 'CSV'
$dir = Join-Path $TestRoot 'csv'; New-Item -ItemType Directory -Path $dir | Out-Null
$enc = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllLines((Join-Path $dir 'rel.csv'), [string[]]@('Title,Password', 'Relative,pw-rel'), $enc)
Push-Location $dir
try { Import-PwCsv -Path 'rel.csv' 6>$null 3>$null } finally { Pop-Location }
Check '相対パスの CSV も取り込める（PowerShell の今いるフォルダーから探す）' (@(Get-PwEntry 'Relative' -All).Count -eq 1)
[IO.File]::WriteAllLines((Join-Path $dir 'quote.csv'), [string[]]@('name,url,username,password,note', "'=keep,,,pw-q,'-note"), $enc)
Import-PwCsv -Path (Join-Path $dir 'quote.csv') 6>$null 3>$null
$q = @(Get-PwEntry -All | Where-Object Title -eq "'=keep")
Check "ほかのツールの CSV では、' で始まる値を削らない" ($q.Count -eq 1 -and $q[0].Note -eq "'-note")
[IO.File]::WriteAllLines((Join-Path $dir 'empty.csv'), [string[]]@('Title,Password'), $enc)
$warn = $null
Import-PwCsv -Path (Join-Path $dir 'empty.csv') -WarningVariable warn 6>$null 3>$null
Check '見出しだけの CSV は、取り込める行が無いと知らせる' ("$warn" -match '取り込める行がありません')
$global:N = 0
$err = $null
try {
    & $Pwm { param($p) $rows = Read-PwCsvRows $p; Import-PwCsvRows $rows (Get-PwConfig) $p { param($a) $global:N++; if ($global:N -eq 2) { throw 'ロック解除がキャンセルされました。' }; & $a } } `
        ([IO.File]::WriteAllLines((Join-Path $dir 'stop.csv'), [string[]]@('Title,Password', 'S1,p', 'S2,p', 'S3,p'), $enc), (Join-Path $dir 'stop.csv'))[1]
} catch { $err = $_ }
Check '途中で止まったら、それまでに取り込んだ件数を知らせる' ($err -and $err.Exception.Message -match '^1 件を取り込んだところで止まりました')

Write-Host '設定'
$cfgPath = Join-Path $env:APPDATA 'PwManager\config.json'
Set-Content -LiteralPath $cfgPath -Value '{ "PasswordGenerator": { "Length": 24 } }' -Encoding UTF8
$pw = New-PwPassword
Check 'PasswordGenerator の一部だけを書いても、ほかの項目（記号）は既定値のまま' ($pw.Length -eq 24 -and $pw -match '[^A-Za-z0-9]')
Remove-Item -LiteralPath $cfgPath

Write-Host '保管庫の登録（SecretStore の場所）'
$global:Reg = New-Object System.Collections.Generic.List[string]
function global:Get-Module { param([switch]$ListAvailable, $Name) [pscustomobject]@{ Name = $Name; Version = [version]'1.0.6'; ModuleBase = 'C:\Local\Programs\PwManager\Modules\Microsoft.PowerShell.SecretStore\1.0.6'; Path = 'C:\Local\Programs\PwManager\Modules\Microsoft.PowerShell.SecretStore\1.0.6\Microsoft.PowerShell.SecretStore.psd1' } }
function global:Register-SecretVault { param($Name, $ModuleName, [switch]$DefaultVault) $global:Reg.Add("register:$Name module=$ModuleName default=$DefaultVault") }
function global:Get-SecretVault { param($Name) if ($global:Registered) { [pscustomobject]@{ Name = 'PwVault'; IsDefault = $true } } }
$global:Registered = $false
& $Pwm { Register-PwVaultIfMissing (Get-PwConfig) } 6>$null
Check '登録されていなければ、SecretStore を psd1 の場所で指定して登録する（PSModulePath の順番に左右されない）' (($global:Reg -join '|') -eq 'register:PwVault module=C:\Local\Programs\PwManager\Modules\Microsoft.PowerShell.SecretStore\1.0.6\Microsoft.PowerShell.SecretStore.psd1 default=True')
$global:Reg.Clear(); $global:Registered = $true
& $Pwm { Register-PwVaultIfMissing (Get-PwConfig) } 6>$null
Check '登録済みなら何もしない' ($global:Reg.Count -eq 0)
Remove-Item function:\Get-Module
function global:Get-SecretVault { [pscustomobject]@{ Name = 'PwVault'; IsDefault = $true } }
Write-Host '削除'
$n = & $Pwm { Save-PwEntry -Title '消すもの' -Password (S 'old') }
[void](& $Pwm { param($n) Save-PwEntry -Name $n -Title '消すもの' -Password (S 'new') } $n)
$orig = & $Pwm { ${function:Use-PwVault} }
& $Pwm { function script:Use-PwVault([scriptblock]$Action) { if ("$Action" -match 'Remove-Secret' -and "$Action" -notmatch 'prev') { throw '削除に失敗（テスト）' }; & $Action } }
try { Remove-PwEntry -Name $n -Confirm:$false } catch { }
& $Pwm { param($f) Set-Item function:script:Use-PwVault $f } $orig
Check '本体の削除に失敗しても、一覧に出ない変更前のパスワードだけが残ることはない' (@($global:Store.Keys | Where-Object { $_ -like 'pwm-prev:*' }).Count -eq 0)

Complete-Test
