. (Join-Path $PSScriptRoot 'TestHelper.ps1')

Write-Host '画面の状態（New-PwUiState）'
$ui = & $Pwm { New-PwUiState (Get-PwConfig) }
$defined = @($ui.PSObject.Properties.Name)

# 画面のコードで使っている $ui.○○ が、すべて New-PwUiState で定義されているか（読み取りの打ち間違いも見つける）
$used = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\PwManager') -Filter 'Gui*.ps1' |
    ForEach-Object { [regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8), '\$ui\.([A-Za-z]+)') } |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unknown = @($used | Where-Object { $defined -notcontains $_ })
Check "コードで使う項目はすべて定義済み$(if ($unknown) { '（未定義: ' + ($unknown -join ', ') + '）' })" ($unknown.Count -eq 0 -and $used.Count -gt 10)

$err = $null
try { $ui.LastActivty = Get-Date } catch { $err = $_ }
Check '定義していない項目への書き込みはエラーになる' ($null -ne $err)
Check '一覧のデータが用意されている' ($null -ne $ui.List.View -and $ui.List.Table.Rows.Count -eq 0)

Complete-Test
