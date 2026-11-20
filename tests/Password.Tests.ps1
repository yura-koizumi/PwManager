. (Join-Path $PSScriptRoot 'TestHelper.ps1')

Write-Host 'パスワードの生成'
$many = { param([hashtable]$p) 1..30 | ForEach-Object { New-PwPassword @p } }

$all = & $many @{}
Check '既定は設定の長さ（20 文字）'                      (@($all | Where-Object Length -ne 20).Count -eq 0)
Check '大文字・小文字・数字・記号を最低 1 文字ずつ含む'  (@($all | Where-Object { $_ -cnotmatch '[A-Z]' -or $_ -cnotmatch '[a-z]' -or $_ -notmatch '\d' -or $_ -notmatch '[^A-Za-z0-9]' }).Count -eq 0)
Check '紛らわしい文字（0 O 1 l I）を使わない'            (@($all | Where-Object { $_ -cmatch '[0O1lI]' }).Count -eq 0)

$an = & $many @{ Length = 12; NoSymbols = $true }
Check '-NoSymbols: 英数字のみ 12 文字'                   (@($an | Where-Object { $_.Length -ne 12 -or $_ -match '[^A-Za-z0-9]' }).Count -eq 0)

$pin = & $many @{ Length = 4; DigitsOnly = $true }
Check '-DigitsOnly: 4 桁の数字（0 と 1 も使う）'         (@($pin | Where-Object { $_ -notmatch '^\d{4}$' }).Count -eq 0 -and (-join $pin) -match '[01]')

$sym = & $many @{ SymbolChars = '!@#' }
Check '-SymbolChars: 指定した記号だけを使う'             (@($sym | Where-Object { $_ -match '[^A-Za-z0-9!@#]' -or $_ -notmatch '[!@#]' }).Count -eq 0)
$sym2 = & $many @{ SymbolChars = 'a! 1' }
Check '-SymbolChars: 英数字や空白は記号として扱わない'   (@($sym2 | Where-Object { $_ -match '[^A-Za-z0-9!]' -or $_ -notmatch '!' }).Count -eq 0)

$s = New-PwPassword -Length 16 -AsSecureString
Check '-AsSecureString: SecureString で返す'             ($s -is [securestring] -and $s.Length -eq 16)

$err = $null; try { New-PwPassword -Length 3 } catch { $err = $_ }
Check '3 文字以下は断る'                                 ($null -ne $err)
$err = $null; try { New-PwPassword -Length 129 } catch { $err = $_ }
Check '129 文字以上は断る'                               ($null -ne $err)

Complete-Test
