# 模擬データで画面を開く（動作の軽さの確認用。実際の保管庫や設定には触れない）
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Demo-Gui.ps1 -Count 3000
#   マスターパスワードは demo-password-1 です。
param([int]$Count = 1000)

. (Join-Path $PSScriptRoot 'TestHelper.ps1')
function global:Unlock-SecretStore { param($Password, $PasswordTimeout) }
[void](New-TestKey 'demo-password-1')

$cats = '仕事', '社内システム', '取引先', '共通', 'その他'
$sec = ConvertTo-SecureString 'demo-password' -AsPlainText -Force
for ($i = 1; $i -le $Count; $i++) {
    $name = 'pwm:' + [guid]::NewGuid().ToString('N')
    $global:Store[$name] = [pscustomobject]@{ Name = $name; Secret = $sec; Metadata = @{
        Title = "サービス $i"; Id = "user$i"; Email = "user$i@example.com"; Url = "https://service$i.example.com"
        Category = $cats[$i % $cats.Count]; Note = "メモ $i"
        Created = '2026-01-01 00:00:00'; Updated = (Get-Date '2026-01-01').AddMinutes($i).ToString('yyyy-MM-dd HH:mm:ss')
    } }
}
Write-Host "模擬データ $Count 件で画面を開きます。"
Show-PwManager
Complete-Test
