. (Join-Path $PSScriptRoot 'TestHelper.ps1')


Write-Host '既定の設定'
$cfg = & $Pwm { Get-PwConfig }
Check '既定の項目は ID・URL・備考' ((@($cfg.Fields | ForEach-Object Name) -join ',') -eq 'Id,Url,Note')
Check '既定ではカテゴリの項目は無い' (-not @($cfg.Fields | Where-Object { $_.Type -eq 'Category' }))
Check '自動バックアップの設定は無い' (-not (@($cfg.Keys) -match '^Backup'))
Check '保管庫を開いたままにする時間は 15 分' ([int]$cfg.UnlockTimeoutSeconds -eq 900)

Complete-Test
