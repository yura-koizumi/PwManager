# Gui.Actions.ps1 - 画面の操作（コピー・登録・編集・削除・バックアップ・ロック）
# （PwManager.psm1 から読み込まれる）

function Set-PwUiClipboard($ui, [string]$Text, [bool]$Sensitive, [string]$What) {
    $seq = Set-PwClipboard -Text $Text -Sensitive:$Sensitive
    $sec = [int]$ui.Cfg.ClipboardClearSeconds
    if ($Sensitive -and $sec -gt 0) {
        $ui.ClipSeq  = $seq
        $ui.ClipHash = Get-PwTextHash $Text
        $ui.ClipExpire = (Get-Date).AddSeconds($sec)
        Set-PwUiStatus $ui "$What をコピーしました（$sec 秒後に消去）"
    } else {
        Set-PwUiStatus $ui "$What をコピーしました"
    }
}

function Copy-PwUiPassword($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $text = Invoke-PwVault $ui { Get-PwPassword $e.Name }
    Set-PwUiClipboard $ui $text $true "「$($e.Title)」のパスワード"
}

function Copy-PwUiField($ui, $Field) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $v = [string]$e.($Field.Name)
    if (-not $v) { Set-PwUiStatus $ui "「$($e.Title)」の$($Field.Label)は空です。" -Warn; return }
    Set-PwUiClipboard $ui $v ([bool]$Field.Sensitive) "「$($e.Title)」の$($Field.Label)"
}

function Copy-PwUiColumn($ui, [string]$ColumnName) {
    switch ($ColumnName) {
        '__Password' { Copy-PwUiPassword $ui; return }
        '__Title'    { $e = Get-PwUiSelected $ui; if ($e) { Set-PwUiClipboard $ui $e.Title $false "「$($e.Title)」のタイトル" }; return }
        '__Updated'  { return }
    }
    $f = @($ui.Cfg.Fields | Where-Object { $_.Name -eq $ColumnName }) | Select-Object -First 1
    if ($f) { Copy-PwUiField $ui $f }
}

function Open-PwUiUrl($ui, $Field) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $v = ([string]$e.($Field.Name)).Trim()
    # 任意のファイルやコマンドを実行しないよう、http(s) の URL だけ開く
    if ($v -notmatch '^https?://') { Set-PwUiStatus $ui "http:// または https:// で始まる$($Field.Label)だけ開けます。" -Warn; return }
    Start-Process $v
}

function New-PwUiEntry($ui) {
    $saved = Show-PwEditDialog $ui $null
    if ($saved) { Update-PwUiAfterChange $ui $saved; Set-PwUiStatus $ui '登録しました。' }
}

function Edit-PwUiEntry($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $saved = Show-PwEditDialog $ui $e
    if ($saved) { Update-PwUiAfterChange $ui $saved; Set-PwUiStatus $ui '更新しました。' }
}

function Remove-PwUiEntry($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $r = [System.Windows.Forms.MessageBox]::Show($ui.Form,
        "「$($e.Title)」を削除しますか？`n`n削除するとバックアップから復元する以外に戻せません。",
        '削除の確認', [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Invoke-PwVault $ui { Remove-PwEntry -Name $e.Name -Confirm:$false }
    Update-PwUiAfterChange $ui $e.Name -Removed
    Set-PwUiStatus $ui "「$($e.Title)」を削除しました。"
}

function Invoke-PwUiBackup($ui, [switch]$Auto) {
    $dest = [Environment]::ExpandEnvironmentVariables([string]$ui.Cfg.BackupFolder)
    if (-not $dest) {
        if ($Auto) { return }
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = "バックアップ先を選んでください。`n毎回選ばずに済ませるには、「設定」で BackupFolder を指定します。"
        if ($fb.ShowDialog($ui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $dest = $fb.SelectedPath
    }
    $zip = Backup-PwVault -Destination $dest
    Set-PwUiStatus $ui ("{0}バックアップしました: {1}" -f $(if ($Auto) { '自動' } else { '' }), $zip.FullName)
}

function Invoke-PwUiStartupBackup($ui) {
    # 前回から BackupIntervalDays 日以上経っていれば、自動バックアップ（保存先未設定なら警告のみ）
    $days = [int]$ui.Cfg.BackupIntervalDays
    if ($days -le 0) { return }
    $last = Get-PwLastBackup
    if ($last -and ((Get-Date) - $last).TotalDays -lt $days) { return }
    if ($ui.Cfg.BackupFolder) {
        try { Invoke-PwUiBackup $ui -Auto }
        catch { Set-PwUiStatus $ui "自動バックアップに失敗しました（保存先: $($ui.Cfg.BackupFolder)）: $($_.Exception.Message)" -Warn }
    } elseif ($last) {
        Set-PwUiStatus $ui "前回のバックアップから $([int]((Get-Date) - $last).TotalDays) 日経っています。「バックアップ」を押してください。" -Warn
    } else {
        Set-PwUiStatus $ui 'まだバックアップがありません。「設定」で BackupFolder を指定すると自動でバックアップします。' -Warn
    }
}

function Lock-PwUi($ui) {
    if ($ui.Locking) { return }
    $ui.Locking = $true
    try {
        Set-PwUiListData $ui @()
        $ui.Count.Text = ''
        foreach ($p in $ui.Panels) { $p.Enabled = $false }
        Set-PwUiStatus $ui 'ロック中'
        if (Show-PwUnlockDialog $ui 'ロックしました。続けるにはマスターパスワードを入力してください。') {
            foreach ($p in $ui.Panels) { $p.Enabled = $true }
            Update-PwUiData $ui
            Set-PwUiStatus $ui 'ロックを解除しました。'
        } else {
            $ui.Form.Close()
        }
    } finally {
        $ui.Locking = $false
        $ui.LastActivity = Get-Date
    }
}

function Invoke-PwUiAutoLock($ui) {
    # 無操作が続いたらロックする。編集などの子画面が開いていれば、内容が画面に残らないよう先に閉じる
    $lockMin = [double]$ui.Cfg.AutoLockMinutes
    if ($lockMin -le 0 -or $ui.Locking -or ((Get-Date) - $ui.LastActivity).TotalMinutes -lt $lockMin) { return }
    $others = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_ -ne $ui.Form })
    if (@($others | Where-Object { $_.Tag -eq 'PwUnlock' }).Count -gt 0) { return }  # すでにマスターパスワードを求めている
    if ($others.Count -gt 0) {
        # 子画面のモーダル処理が終わってからロックする（次のタイマーで再判定）
        foreach ($f in $others) { $f.Close() }
        return
    }
    Lock-PwUi $ui
}

