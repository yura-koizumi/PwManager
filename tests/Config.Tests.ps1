. (Join-Path $PSScriptRoot 'TestHelper.ps1')

$cfgPath = Join-Path $env:APPDATA 'PwManager\config.json'

Write-Host '既定の設定'
$cfg = & $Pwm { Get-PwConfig }
Check '既定の項目は ID・URL・備考' ((@($cfg.Fields | ForEach-Object Name) -join ',') -eq 'Id,Url,Note')
Check '既定ではカテゴリの項目は無い' (-not @($cfg.Fields | Where-Object { $_.Type -eq 'Category' }))

Write-Host '設定の 1 項目だけの書き換え（Set-PwConfigValue）'
& $Pwm { Set-PwConfigValue 'BackupFolder' 'D:\Backup' }
Check '設定ファイルが無ければ作る' ((Test-Path -LiteralPath $cfgPath) -and (& $Pwm { Get-PwConfig }).BackupFolder -eq 'D:\Backup')
'{ "AutoLockMinutes": 3, "Fields": [ { "Name": "Id", "Label": "ユーザー" } ] }' | Set-Content -LiteralPath $cfgPath -Encoding UTF8
& $Pwm { Set-PwConfigValue 'BackupFolder' 'E:\日本語\バックアップ' }
$c = & $Pwm { Get-PwConfig }
Check '書き換えた項目が反映される'       ($c.BackupFolder -eq 'E:\日本語\バックアップ')
Check 'ほかの項目は変えない'             ($c.AutoLockMinutes -eq 3 -and $c.Fields[0].Label -eq 'ユーザー' -and @($c.Fields).Count -eq 1)
$shown = & $Pwm {
    $script:PinnedConfig = Get-PwConfig
    try { Set-PwConfigValue 'BackupFolder' 'F:\x'; $script:PinnedConfig.BackupFolder } finally { $script:PinnedConfig = $null }
}
Check '画面の表示中は、表示中の設定にも反映する' ($shown -eq 'F:\x' -and (& $Pwm { Get-PwConfig }).BackupFolder -eq 'F:\x')

Complete-Test
