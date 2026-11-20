# 実際の Windows Forms の画面を短時間表示する（ロック本体 Lock-PwUi だけモック）
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
$autoLock = & $Pwm { ${function:Invoke-PwUiAutoLock} }
$register = & $Pwm { ${function:Register-PwActivity} }
$bind = [Reflection.BindingFlags]'Instance,NonPublic'

Write-Host '操作の検知'
$ui = @{ LastActivity = (Get-Date).AddHours(-1) }
$dlg = New-Object System.Windows.Forms.Form
$tb = New-Object System.Windows.Forms.TextBox
$dlg.Controls.Add($tb)
& $register $ui $dlg
[System.Windows.Forms.TextBox].GetMethod('OnMouseDown', $bind).Invoke($tb, @([System.Windows.Forms.MouseEventArgs]::new('Left', 1, 0, 0, 0)))
Check '子画面の部品のクリックを操作として数える' (((Get-Date) - $ui.LastActivity).TotalSeconds -lt 5)
$ui.LastActivity = (Get-Date).AddHours(-1)
[System.Windows.Forms.Form].GetMethod('OnKeyDown', $bind).Invoke($dlg, @([System.Windows.Forms.KeyEventArgs]::new('A')))
Check '子画面のキー入力を操作として数える' (((Get-Date) - $ui.LastActivity).TotalSeconds -lt 5)
$dlg.Dispose()

Write-Host '子画面を開いたままの自動ロック'
& $Pwm { function script:Lock-PwUi($ui) { $ui.Log.Add("lock(childOpen=$($ui.ChildOpen))"); $ui.Form.Close() } }
$ui = @{
    Cfg = @{ AutoLockMinutes = 0.01 }; Locking = $false; LastActivity = (Get-Date).AddMinutes(-5)
    Log = New-Object System.Collections.Generic.List[string]; ChildOpen = $false
}
$main = New-Object System.Windows.Forms.Form
$ui.Form = $main
$timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 200 }
$timer.Add_Tick({ & $autoLock $ui })
$safety = New-Object System.Windows.Forms.Timer -Property @{ Interval = 8000 }
$safety.Add_Tick({ $ui.Log.Add('timeout'); foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) { $f.Close() } })
$main.Add_Shown({
    $timer.Start(); $safety.Start()
    # マスターパスワード再入力の画面（Tag=PwUnlock）
    $unlock = New-Object System.Windows.Forms.Form -Property @{ Tag = 'PwUnlock' }
    $later = New-Object System.Windows.Forms.Timer -Property @{ Interval = 1500 }
    $later.Add_Tick({ $later.Stop(); $ui.Log.Add("unlock-open=$($unlock.Visible)"); $unlock.Close() })
    $later.Start()
    [void]$unlock.ShowDialog($main); $unlock.Dispose()
    $ui.Log.Add('unlock-closed')
    # 編集画面
    $edit = New-Object System.Windows.Forms.Form
    $ui.ChildOpen = $true
    [void]$edit.ShowDialog($main)
    $ui.ChildOpen = $false
    $ui.Log.Add('edit-closed'); $edit.Dispose()
})
[void]$main.ShowDialog()
$timer.Dispose(); $safety.Dispose(); $main.Dispose()
$log = $ui.Log
Check 'マスターパスワード再入力の画面も閉じる（出したまま離席しても、後ろの一覧を出し続けない）' ($log -contains 'unlock-closed' -and $log -notcontains 'unlock-open=True')
Check '編集画面を閉じてからロックする' ($log.IndexOf('edit-closed') -ge 0 -and $log.IndexOf('edit-closed') -lt $log.IndexOf('lock(childOpen=False)'))
Check '時間切れにならない' ($log -notcontains 'timeout')

Complete-Test
