. (Join-Path $PSScriptRoot 'TestHelper.ps1')

Write-Host 'ヘルプ'
$exported = @((Get-Module PwManager).ExportedFunctions.Keys)
$listed = @(& $Pwm { $script:HelpGroups.Values | ForEach-Object { $_ } })
$missing = @($exported | Where-Object { $_ -notin $listed })
$extra = @($listed | Where-Object { $_ -notin $exported })
Check "公開しているコマンドは、すべて Get-PwHelp の一覧にある（漏れ: $($missing -join ', ')）" ($missing.Count -eq 0)
Check "Get-PwHelp の一覧に、公開していないコマンドは無い（余分: $($extra -join ', ')）" ($extra.Count -eq 0)

$common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters + 'First', 'Skip', 'IncludeTotalCount'
foreach ($c in $exported) {
    $h = Get-Help $c -Full
    $noSyn = -not $h.Synopsis -or $h.Synopsis -match "^\s*$c\b"    # ヘルプが無いと、構文がそのまま入る
    $noEx = @($h.examples.example).Count -eq 0
    $params = @((Get-Command $c).Parameters.Keys | Where-Object { $_ -notin $common })
    $noDesc = @($params | Where-Object { $p = $_; -not (@($h.parameters.parameter | Where-Object { $_.name -eq $p })[0].description) })
    Check "$c : 概要・例・引数の説明がある$(if ($noDesc) { "（説明の無い引数: $($noDesc -join ', ')）" })" (-not $noSyn -and -not $noEx -and $noDesc.Count -eq 0)
}

$rows = @(Get-PwHelp 6>$null)
Check 'Get-PwHelp は分類・コマンド・内容の一覧を返す' ($rows.Count -eq $listed.Count -and $rows[0].コマンド -eq 'pwm' -and @($rows | Where-Object { -not $_.内容 }).Count -eq 0)
Check 'Get-PwHelp <名前の一部> で、そのコマンドの例を表示する' (@((Get-PwHelp MasterPassword).examples.example).Count -ge 1)
$err = $null; try { Get-PwHelp Pw } catch { $err = $_ }
Check '名前が複数に当たるときは、候補を示して止まる' ($err -and $err.Exception.Message -match 'Get-PwEntry')

Complete-Test
