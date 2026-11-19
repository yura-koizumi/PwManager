# すべてのテストを、それぞれ新しい PowerShell（STA）で実行する
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
# PwManager の画面は閉じてから実行すること（復元のテストが、画面の起動中と判定するため）
$failed = @()
foreach ($t in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1') {
    Write-Host "== $($t.Name)" -ForegroundColor Cyan
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $t.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $t.Name }
}
if ($failed) { Write-Host "失敗: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'すべて成功しました。' -ForegroundColor Green
