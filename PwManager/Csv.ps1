# Csv.ps1 - CSV の取り込み・書き出し（Excel からの移行）
# （PwManager.psm1 から読み込まれる）

# Excel で開いたとき数式として実行されないよう、= + - @ タブ CR で始まる値の先頭に ' を付ける。
# パスワードは値を変えないため対象外。Import-PwCsv は付けた ' を取り除く。
$script:CsvFormulaPattern = "^[=+\-@`t`r]"

function Protect-PwCsvValue([string]$Value) {
    if ($Value -match $script:CsvFormulaPattern) { "'" + $Value } else { $Value }
}

function Unprotect-PwCsvValue([string]$Value) {
    if ($Value.Length -gt 1 -and $Value[0] -eq "'" -and $Value.Substring(1) -match $script:CsvFormulaPattern) { $Value.Substring(1) } else { $Value }
}

function Import-PwCsv {
    <#
    .SYNOPSIS
      Excel 等から書き出した CSV を取り込む。
      必須列: Title(またはタイトル/サービス) と Password(またはパスワード)。
      その他の列は、設定 Fields の Name または Label と同じ見出しなら取り込む。
      Excel の「CSV (コンマ区切り)」は -Encoding Default、「CSV UTF-8」は既定の UTF8。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('UTF8', 'Default')][string]$Encoding = 'UTF8'
    )
    $cfg = Get-PwConfig
    $rows = @(Import-Csv -LiteralPath $Path -Encoding $Encoding)
    $pick = {
        param($Row, [string[]]$Keys)
        foreach ($k in $Keys) { $p = $Row.PSObject.Properties[$k]; if ($p -and $p.Value) { return [string]$p.Value } }
        ''
    }
    $ok = 0; $skip = 0
    foreach ($r in $rows) {
        $title = Unprotect-PwCsvValue (& $pick $r @('Title', 'タイトル', 'サービス', 'Service', 'サービス名'))
        $pw    = & $pick $r @('Password', 'パスワード', 'PW')
        if (-not $title -or -not $pw) { $skip++; continue }
        $fields = @{}
        foreach ($f in @($cfg.Fields)) { $fields[$f.Name] = Unprotect-PwCsvValue (& $pick $r @($f.Name, $f.Label)) }
        Save-PwEntry -Title $title -Fields $fields -Password (ConvertTo-SecureString $pw -AsPlainText -Force) | Out-Null
        $ok++
    }
    Write-PwAudit 'IMPORT' "$Path ($ok 件)"
    Write-Host "$ok 件を取り込みました。（タイトルかパスワードが空でスキップ: $skip 件）" -ForegroundColor Green
    Write-Warning "取り込みが済んだら、元の CSV / Excel ファイルは削除してください（パスワードが平文で残っています）。"
}

function Export-PwCsv {
    <#
    .SYNOPSIS
      一覧を CSV に書き出す（ほかのツールへの移行用）。-IncludePassword を付けるとパスワードを平文で含める。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludePassword
    )
    $cfg = Get-PwConfig
    if ($IncludePassword -and -not $PSCmdlet.ShouldProcess($Path, 'パスワードを平文で書き出す')) { return }
    $rows = foreach ($e in @(Get-PwEntry)) {
        $h = [ordered]@{ Title = Protect-PwCsvValue $e.Title }
        if ($IncludePassword) { $h['Password'] = Get-PwPassword $e.Name }
        foreach ($f in @($cfg.Fields)) { $h[$f.Name] = Protect-PwCsvValue $e.($f.Name) }
        $h['Updated'] = $e.Updated
        [pscustomobject]$h
    }
    @($rows) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    Write-PwAudit $(if ($IncludePassword) { 'EXPORT+PW' } else { 'EXPORT' }) $Path
    if ($IncludePassword) { Write-Warning '平文のパスワードを含むファイルです。用が済んだらすぐに削除してください。' }
}

