# 2 回目のリリース前の確認（Sonnet による解析）で見つかった不具合が、再び起きないことを確かめる
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
$global:Copied = $null; $global:CopiedSecret = $false
& $Pwm { function script:Set-PwClipboard($Text, $Secret, [switch]$Sensitive) { $global:CopiedSecret = [bool]$Secret; $global:Copied = if ($Secret) { Plain $Secret } else { $Text }; 1 }; function script:Start-PwClipboardClearJob { } }
$cfgPath = Join-Path $env:APPDATA 'PwManager\config.json'
$dir = Join-Path $TestRoot 'csv'; New-Item -ItemType Directory -Path $dir | Out-Null
$enc = New-Object Text.UTF8Encoding $false

Write-Host '自分で足した項目'
Set-Content -LiteralPath $cfgPath -Encoding UTF8 -Value '{ "Fields": [ { "Name": "Id", "Label": "ID" }, { "Name": "Pin", "Label": "暗証番号", "Sensitive": true } ] }'
[IO.File]::WriteAllLines((Join-Path $dir 'custom.csv'), [string[]]@('Title,Password,ID,暗証番号', 'Bank,pw-b,u1,1234'), $enc)
Import-PwCsv -Path (Join-Path $dir 'custom.csv') 6>$null 3>$null
$e = @(Get-PwEntry -All | Where-Object Title -eq 'Bank')
Check '別名の無い項目（自分で足した項目）があっても、CSV を取り込める' ($e.Count -eq 1 -and $e[0].Pin -eq '1234' -and $e[0].Id -eq 'u1')
Copy-PwField 'Bank' 暗証番号 6>$null
Check '秘密にする項目（Sensitive）は、SecureString でクリップボードに渡す（ログに残らないように）' ($global:CopiedSecret -and $global:Copied -eq '1234')
Copy-PwField 'Bank' ID 6>$null
Check 'ふつうの項目は文字列で渡す' (-not $global:CopiedSecret -and $global:Copied -eq 'u1')
Remove-Item -LiteralPath $cfgPath

Write-Host 'タイトルの完全一致'
[void](& $Pwm { Save-PwEntry -Title 'Case' -Password (S 'pw-upper') })
[void](& $Pwm { Save-PwEntry -Title 'case' -Password (S 'pw-lower') })
function global:Out-GridView { throw '選ぶ画面を出した' }
Copy-PwField 'case' 6>$null
Check '大文字小文字まで一致するタイトルがあれば、選ぶ画面を出さずにそれにする' ($global:Copied -eq 'pw-lower')
Remove-Item function:\Out-GridView

Write-Host 'バックアップ'
$store = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement\localstore'
New-Item -ItemType Directory -Path $store -Force | Out-Null; Set-Content -LiteralPath (Join-Path $store 'storefile') -Value 'v1'
[void](New-TestKey 'master-password-1')
$zip = Join-Path $dir 'same.zip'
Set-Content -LiteralPath $zip -Value 'earlier backup'
$err = $null; try { & $Pwm { param($z) Save-PwArchive $z } $zip } catch { $err = $_ }
Check '同じ名前のファイルがあれば、先のバックアップを消さずに知らせる' ($err -and (Get-Content -LiteralPath $zip) -eq 'earlier backup')

Write-Host 'パスワードの生成（画面）'
$src = & $Pwm { ${function:Show-PwEditDialog}.ToString() }
Check '「英数字と記号」では、設定で記号を使わないことにしていても記号を入れる（-SymbolChars を渡す）' ($src -match 'SymbolChars = if \(\$chars\)')
Set-Content -LiteralPath $cfgPath -Encoding UTF8 -Value '{ "PasswordGenerator": { "Symbols": false } }'
Check '-SymbolChars を渡せば、設定で記号を使わないことにしていても記号が入る' ((New-PwPassword -SymbolChars '!#') -match '[!#]')
Remove-Item -LiteralPath $cfgPath

Write-Host '設定の値の種類'
foreach ($bad in '{ "ClipboardClearSeconds": "abc" }', '{ "AutoLockMinutes": -1 }', '{ "ExcludeFromClipboardHistory": "false" }', '{ "PasswordGenerator": { "Symbols": "false" } }') {
    Set-Content -LiteralPath $cfgPath -Encoding UTF8 -Value $bad
    $err = $null; try { [void](& $Pwm { Get-PwConfig }) } catch { $err = $_ }
    Check "誤った値の種類は、読み込むときに知らせる: $bad" ($null -ne $err)
}
Set-Content -LiteralPath $cfgPath -Encoding UTF8 -Value '{ "ClipboardClearSeconds": 0, "AutoLockMinutes": 2.5 }'
$err = $null; try { [void](& $Pwm { Get-PwConfig }) } catch { $err = $_ }
Check '0 や小数は受け付ける' ($null -eq $err)
Remove-Item -LiteralPath $cfgPath

Complete-Test
