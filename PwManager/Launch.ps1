# ショートカットから呼ばれる起動用スクリプト（コンソールは非表示）
#   -Locked : ロックしたあとに起動し直したところ
param([switch]$Locked)
try {
    Import-Module (Join-Path $PSScriptRoot 'PwManager.psd1') -Force -ErrorAction Stop
    Show-PwManager -RelaunchOnLock -Locked:$Locked
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "PwManager を起動できませんでした。`n`n$($_.Exception.Message)",
        'PwManager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}
