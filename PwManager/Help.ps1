# Help.ps1 - コマンドの一覧（Get-PwHelp）
# （PwManager.psm1 から読み込まれる）
# 各コマンドの説明は、それぞれの関数のヘルプ（.SYNOPSIS）から取る。ここには分類と並び順だけを書く。
# コマンドを足したときは、ここにも追加する（tests\Help.Tests.ps1 で漏れを確かめる）。

$script:HelpGroups = [ordered]@{
    '使う'           = 'Show-PwManager', 'Get-PwEntry', 'Copy-PwField', 'New-PwPassword'
    '登録・編集'     = 'New-PwEntry', 'Set-PwEntry', 'Remove-PwEntry'
    '移行'           = 'Backup-PwVault', 'Restore-PwVault', 'Import-PwCsv', 'Export-PwCsv'
    '鍵'             = 'Set-PwMasterPassword', 'New-PwRecoveryKey'
    '設定'           = 'Edit-PwConfig', 'Initialize-PwManager', 'Install-PwShortcut', 'Get-PwHelp'
}

function Get-PwHelp {
    <#
    .SYNOPSIS
      PwManager のコマンドの一覧を表示する。
    .DESCRIPTION
      各コマンドの引数の説明と例は Get-PwHelp <コマンド>（または Get-Help <コマンド> -Detailed）で表示する。
    .PARAMETER Name
      コマンド名（一部でよい）。指定すると、そのコマンドの引数の説明と例を表示する。
    .EXAMPLE
      Get-PwHelp
    .EXAMPLE
      Get-PwHelp Get-PwEntry     # Get-Help Get-PwEntry -Detailed と同じ
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    if ($Name) {
        if ($Name -eq 'pwm') { $Name = 'Show-PwManager' }   # 一覧では別名の pwm で表示している
        $pattern = '*' + [WildcardPattern]::Escape($Name) + '*'
        $cmd = @($script:HelpGroups.Values | ForEach-Object { $_ } | Where-Object { $_ -like $pattern })
        $exact = @($cmd | Where-Object { $_ -eq $Name }); if ($exact.Count -eq 1) { $cmd = $exact }
        if ($cmd.Count -eq 0) { throw "「$Name」に当たるコマンドはありません。一覧は Get-PwHelp で表示します。" }
        if ($cmd.Count -gt 1) { throw "「$Name」に当たるコマンドが $($cmd.Count) 件あります: $($cmd -join ', ')" }
        return Get-Help $cmd[0] -Detailed   # 概要・引数の説明・例
    }
    Write-Host 'PwManager のコマンド（詳しい使い方と例は Get-PwHelp <コマンド>、または Get-Help <コマンド> -Full）' -ForegroundColor Cyan
    foreach ($g in $script:HelpGroups.Keys) {
        foreach ($c in $script:HelpGroups[$g]) {
            $syn = ((Get-Help $c).Synopsis -split "`r?`n")[0].Trim()
            [pscustomobject]@{ 分類 = $g; コマンド = $(if ($c -eq 'Show-PwManager') { 'pwm' } else { $c }); 内容 = $syn }
        }
    }
}
