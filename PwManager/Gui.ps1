# Gui.ps1 - Windows Forms による画面（PwManager.psm1 から読み込まれる）

#region 部品 -------------------------------------------------------------------

function New-PwControl([string]$Type, [hashtable]$Property = @{}) {
    New-Object -TypeName "System.Windows.Forms.$Type" -Property $Property
}
function New-PwPadding([int]$L, [int]$T = $L, [int]$R = $L, [int]$B = $T) {
    New-Object System.Windows.Forms.Padding($L, $T, $R, $B)
}
function New-PwSize([int]$W, [int]$H) { New-Object System.Drawing.Size($W, $H) }
function New-PwButton([string]$Text) {
    New-PwControl Button @{ Text = $Text; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = (New-PwPadding 6 2) }
}

function Show-PwMessage([string]$Text, [string]$Kind = 'Info') {
    $icon = switch ($Kind) {
        'Error' { [System.Windows.Forms.MessageBoxIcon]::Error }
        'Warn'  { [System.Windows.Forms.MessageBoxIcon]::Warning }
        default { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'PwManager', [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
}

function Invoke-PwUi($ui, [scriptblock]$Action) {
    # 画面操作でのエラーを握りつぶさず、メッセージで表示する
    try { & $Action } catch { Show-PwMessage $_.Exception.Message 'Error' }
}

function Invoke-PwVault($ui, [scriptblock]$Action) {
    # ロック解除の有効期限切れが近ければ先に再入力を求め、ロックエラーなら解除して1回だけ再試行する
    if ($ui.UnlockedAt -and ((Get-Date) - $ui.UnlockedAt).TotalSeconds -gt ([int]$ui.Cfg.UnlockTimeoutSeconds - 60)) {
        if (-not (Show-PwUnlockDialog $ui '一定時間が経過しました。マスターパスワードを再入力してください。')) { throw 'ロック解除がキャンセルされました。' }
    }
    try { & $Action }
    catch {
        if (-not (Test-PwLockedError $_)) { throw }
        if (-not (Show-PwUnlockDialog $ui '保管庫がロックされています。マスターパスワードを入力してください。')) { throw 'ロック解除がキャンセルされました。' }
        & $Action
    }
}

function Set-PwUiStatus($ui, [string]$Text, [switch]$Warn) {
    $ui.Status.Text = $Text
    $ui.Status.ForeColor = if ($Warn) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.SystemColors]::ControlText }
}

#endregion

#region ダイアログ ---------------------------------------------------------------

function Show-PwUnlockDialog($ui, [string]$Message = 'マスターパスワードを入力してください。') {
    $dlg = New-PwControl Form @{
        Text = 'PwManager - ロック解除'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        Font = $ui.Font; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = (New-PwPadding 12); TopMost = $true
    }
    $layout  = New-PwControl TableLayoutPanel @{ ColumnCount = 1; AutoSize = $true; Dock = 'Fill' }
    $msg     = New-PwControl Label @{ Text = $Message; AutoSize = $true; MaximumSize = (New-PwSize 380 0); Margin = (New-PwPadding 3 3 3 8) }
    $tb      = New-PwControl TextBox @{ Width = 380; UseSystemPasswordChar = $true }
    $err     = New-PwControl Label @{ AutoSize = $true; ForeColor = [System.Drawing.Color]::Firebrick; MaximumSize = (New-PwSize 380 0) }
    $buttons = New-PwControl FlowLayoutPanel @{ FlowDirection = 'RightToLeft'; AutoSize = $true; Dock = 'Fill'; Margin = (New-PwPadding 0 8 0 0) }
    $cancel  = New-PwButton 'キャンセル'; $cancel.DialogResult = 'Cancel'
    $ok      = New-PwButton 'ロック解除'
    $buttons.Controls.AddRange([System.Windows.Forms.Control[]]@($cancel, $ok))
    $layout.Controls.AddRange([System.Windows.Forms.Control[]]@($msg, $tb, $err, $buttons))
    $dlg.Controls.Add($layout)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    $state = @{ Ok = $false; Tries = 0 }
    $ok.Add_Click({
        if (-not $tb.Text) { return }
        $sec = ConvertTo-SecureString $tb.Text -AsPlainText -Force
        $tb.Clear()
        $dlg.UseWaitCursor = $true
        try {
            Unlock-PwVault $sec
            $state.Ok = $true
            $ui.UnlockedAt = Get-Date
            $ui.LastActivity = Get-Date
            $dlg.Close()
        } catch {
            $state.Tries++
            $err.Text = "ロック解除できませんでした（$($state.Tries) 回目）。`n$($_.Exception.Message)"
            if ($state.Tries -ge 5) { $dlg.Close() }
        } finally { $dlg.UseWaitCursor = $false }
    })
    $dlg.Add_Shown({ $dlg.Activate(); [void]$tb.Focus() })

    if ($ui.Form -and $ui.Form.Visible) {
        $dlg.StartPosition = 'CenterParent'; [void]$dlg.ShowDialog($ui.Form)
    } else {
        $dlg.StartPosition = 'CenterScreen'; [void]$dlg.ShowDialog()
    }
    $dlg.Dispose()
    $state.Ok
}

function Show-PwEditDialog($ui, $Entry) {
    # 保存したらシークレット名を、キャンセルなら $null を返す
    $cfg = $ui.Cfg
    $isNew = -not $Entry
    $dlg = New-PwControl Form @{
        Text = $(if ($isNew) { '新規登録' } else { "編集 - $($Entry.Title)" })
        FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
        StartPosition = 'CenterParent'; Font = $ui.Font; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = (New-PwPadding 12)
    }
    $t = New-PwControl TableLayoutPanel @{ ColumnCount = 2; AutoSize = $true; Dock = 'Fill' }
    $row = @{ i = 0 }
    $addRow = {
        param([string]$Label, $Control)
        $l = New-PwControl Label @{ Text = $Label; AutoSize = $true; Margin = (New-PwPadding 3 7 10 3) }
        $t.Controls.Add($l, 0, $row.i)
        $t.Controls.Add($Control, 1, $row.i)
        $row.i++
    }

    $title = New-PwControl TextBox @{ Width = 440; Text = $(if ($Entry) { $Entry.Title } else { '' }) }
    & $addRow 'タイトル *' $title

    $inputs = @{}
    foreach ($f in @($cfg.Fields)) {
        $val = if ($Entry) { [string]$Entry.($f.Name) } else { '' }
        if ($f.Type -eq 'Category') {
            $c = New-PwControl ComboBox @{ Width = 440; DropDownStyle = 'DropDown' }
            $items = @(@($cfg.Categories) + @($ui.Entries | ForEach-Object { $_.($f.Name) }) | Where-Object { $_ } | Select-Object -Unique)
            foreach ($i in $items) { [void]$c.Items.Add([string]$i) }
            $c.Text = $val
        } elseif ($f.Multiline) {
            $c = New-PwControl TextBox @{ Width = 440; Height = 90; Multiline = $true; ScrollBars = 'Vertical'; AcceptsReturn = $true; Text = $val }
        } else {
            $c = New-PwControl TextBox @{ Width = 440; Text = $val }
        }
        $inputs[$f.Name] = $c
        & $addRow $f.Label $c
    }

    $pwPanel = New-PwControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false; Margin = (New-PwPadding 0) }
    $pw   = New-PwControl TextBox @{ Width = 280; UseSystemPasswordChar = $true }
    $show = New-PwControl CheckBox @{ Text = '表示'; AutoSize = $true; Margin = (New-PwPadding 8 5 3 3) }
    $gen  = New-PwButton '生成'
    $pwPanel.Controls.AddRange([System.Windows.Forms.Control[]]@($pw, $show, $gen))
    & $addRow $(if ($isNew) { 'パスワード *' } else { 'パスワード' }) $pwPanel
    if (-not $isNew) {
        $hint = New-PwControl Label @{ Text = '空欄のままなら、パスワードは変更しません。'; AutoSize = $true; ForeColor = [System.Drawing.SystemColors]::GrayText }
        & $addRow '' $hint
    }

    $btns   = New-PwControl FlowLayoutPanel @{ FlowDirection = 'RightToLeft'; AutoSize = $true; Dock = 'Fill'; Margin = (New-PwPadding 0 10 0 0) }
    $cancel = New-PwButton 'キャンセル'; $cancel.DialogResult = 'Cancel'
    $save   = New-PwButton '保存'
    $btns.Controls.AddRange([System.Windows.Forms.Control[]]@($cancel, $save))
    $t.Controls.Add($btns, 1, $row.i)

    $dlg.Controls.Add($t)
    $dlg.CancelButton = $cancel
    $state = @{ Saved = $null }

    $show.Add_CheckedChanged({ $pw.UseSystemPasswordChar = -not $show.Checked })
    $gen.Add_Click({ Invoke-PwUi $ui { $pw.Text = New-PwPassword; $show.Checked = $true } })
    $save.Add_Click({
        Invoke-PwUi $ui {
            $tt = $title.Text.Trim()
            if (-not $tt) { Show-PwMessage 'タイトルを入力してください。' 'Warn'; [void]$title.Focus(); return }
            if ($isNew -and -not $pw.Text) { Show-PwMessage 'パスワードを入力してください（「生成」で自動作成もできます）。' 'Warn'; [void]$pw.Focus(); return }
            $fields = @{}
            foreach ($k in $inputs.Keys) { $fields[$k] = $inputs[$k].Text }
            $sec  = if ($pw.Text) { ConvertTo-SecureString $pw.Text -AsPlainText -Force } else { $null }
            $name = if ($Entry) { $Entry.Name } else { $null }
            $dlg.UseWaitCursor = $true
            try { $state.Saved = Invoke-PwVault $ui { Save-PwEntry -Name $name -Title $tt -Fields $fields -Password $sec } }
            finally { $dlg.UseWaitCursor = $false }
            $pw.Clear()
            $dlg.Close()
        }
    })
    $dlg.Add_Shown({ [void]$title.Focus() })

    [void]$dlg.ShowDialog($ui.Form)
    $dlg.Dispose()
    $state.Saved
}

#endregion

#region 画面の動作 -----------------------------------------------------------------

function Get-PwUiSelected($ui) {
    $r = $ui.Grid.CurrentRow
    if ($r -and $r.Tag) { return $r.Tag }
    Set-PwUiStatus $ui '行を選択してください。' -Warn
    $null
}

function Update-PwUiCategories($ui) {
    if (-not $ui.CategoryField) { return }
    $cb = $ui.Category
    $cur = [string]$cb.SelectedItem
    $all = '(すべて)'
    $items = @($all) + @(@($ui.Cfg.Categories) + @($ui.Entries | ForEach-Object { $_.($ui.CategoryField.Name) }) |
        Where-Object { $_ } | Select-Object -Unique)
    $ui.Suspend = $true
    try {
        $cb.BeginUpdate(); $cb.Items.Clear()
        foreach ($i in $items) { [void]$cb.Items.Add([string]$i) }
        $cb.EndUpdate()
        $idx = $cb.Items.IndexOf($cur)
        $cb.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    } finally { $ui.Suspend = $false }
}

function Update-PwGrid($ui) {
    if ($ui.Suspend) { return }
    $g = $ui.Grid
    $target = if ($ui.SelectName) { $ui.SelectName } elseif ($g.CurrentRow -and $g.CurrentRow.Tag) { $g.CurrentRow.Tag.Name } else { $null }
    $ui.SelectName = $null
    $q = $ui.Search.Text.Trim()
    $catFilter = if ($ui.CategoryField -and $ui.Category.SelectedIndex -gt 0) { [string]$ui.Category.SelectedItem } else { $null }

    $g.Rows.Clear()
    $selectIndex = 0
    foreach ($e in $ui.Entries) {
        if ($catFilter -and $e.($ui.CategoryField.Name) -ne $catFilter) { continue }
        if (-not (Test-PwMatch $e $q $ui.Cfg)) { continue }
        $vals = @($e.Title, '••••••••') +
                @(foreach ($f in @($ui.Cfg.Fields)) { ([string]$e.($f.Name)) -replace '\r?\n', ' ' }) +
                @($e.Updated)
        $i = $g.Rows.Add([object[]]$vals)
        $g.Rows[$i].Tag = $e
        if ($target -and $e.Name -eq $target) { $selectIndex = $i }
    }
    if ($g.Rows.Count -gt 0) { $g.CurrentCell = $g.Rows[$selectIndex].Cells[0] }
    $ui.Count.Text = "$($g.Rows.Count) / $(@($ui.Entries).Count) 件"
}

function Update-PwUiData($ui) {
    $ui.Form.UseWaitCursor = $true
    try {
        $ui.Entries = @(Invoke-PwVault $ui { Get-PwEntry })
        Update-PwUiCategories $ui
        Update-PwGrid $ui
    } finally { $ui.Form.UseWaitCursor = $false }
}

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
    if ($saved) { $ui.SelectName = $saved; Update-PwUiData $ui; Set-PwUiStatus $ui '登録しました。' }
}

function Edit-PwUiEntry($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $saved = Show-PwEditDialog $ui $e
    if ($saved) { $ui.SelectName = $saved; Update-PwUiData $ui; Set-PwUiStatus $ui '更新しました。' }
}

function Remove-PwUiEntry($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $r = [System.Windows.Forms.MessageBox]::Show($ui.Form,
        "「$($e.Title)」を削除しますか？`n`n削除するとバックアップから復元する以外に戻せません。",
        '削除の確認', [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Invoke-PwVault $ui { Remove-PwEntry -Name $e.Name -Confirm:$false }
    Update-PwUiData $ui
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
        $ui.Entries = @()
        $ui.Grid.Rows.Clear()
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

#endregion

#region メイン画面 -----------------------------------------------------------------

function Show-PwManager {
    <#
    .SYNOPSIS
      パスワード管理画面を開く（別名: pwm）
    #>
    [CmdletBinding()] param()
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        throw '画面は STA モードで実行してください（powershell.exe -STA）。'
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\PwManager-GUI')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Show-PwMessage 'PwManager はすでに起動しています。'; $mutex.Dispose(); return }

    $form = $null
    $ui = $null
    try {
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $cfg = Get-PwConfig
        $script:PinnedConfig = $cfg
        $ui = @{
            Cfg = $cfg; Entries = @(); Form = $null; Suspend = $false; SelectName = $null
            Font = New-Object System.Drawing.Font('Yu Gothic UI', 10)
            ClipSeq = $null; ClipHash = $null; ClipExpire = $null
            LastActivity = Get-Date; UnlockedAt = $null; Locking = $false
            CategoryField = @($cfg.Fields | Where-Object { $_.Type -eq 'Category' }) | Select-Object -First 1
        }

        if (-not (Show-PwUnlockDialog $ui)) { return }

        # ---- 画面の組み立て ----
        $form = New-PwControl Form @{
            Text = "PwManager - $env:USERNAME"; StartPosition = 'CenterScreen'
            Size = (New-PwSize 1240 680); MinimumSize = (New-PwSize 720 400); Font = $ui.Font; KeyPreview = $true
        }
        $ui.Form = $form

        $top = New-PwControl FlowLayoutPanel @{ Dock = 'Top'; AutoSize = $true; Padding = (New-PwPadding 6 6 6 2) }
        $search = New-PwControl TextBox @{ Width = 260 }
        $ui.Search = $search
        $top.Controls.Add((New-PwControl Label @{ Text = '検索'; AutoSize = $true; Margin = (New-PwPadding 3 8 3 3) }))
        $top.Controls.Add($search)
        $catBox = New-PwControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 160 }
        $ui.Category = $catBox
        if ($ui.CategoryField) {
            $top.Controls.Add((New-PwControl Label @{ Text = $ui.CategoryField.Label; AutoSize = $true; Margin = (New-PwPadding 12 8 3 3) }))
            $top.Controls.Add($catBox)
        }
        $btnNew    = New-PwButton '新規 (Ctrl+N)'
        $btnEdit   = New-PwButton '編集 (F2)'
        $btnDel    = New-PwButton '削除 (Del)'
        $btnReload = New-PwButton '再読込 (F5)'
        $btnBackup = New-PwButton 'バックアップ'
        $btnConfig = New-PwButton '設定'
        $btnLock   = New-PwButton 'ロック (Ctrl+L)'
        $btnNew.Margin = New-PwPadding 16 3 3 3
        $top.Controls.AddRange([System.Windows.Forms.Control[]]@($btnNew, $btnEdit, $btnDel, $btnReload, $btnBackup, $btnConfig, $btnLock))

        $copyBar = New-PwControl FlowLayoutPanel @{ Dock = 'Top'; AutoSize = $true; Padding = (New-PwPadding 6 0 6 4) }
        $btnPw = New-PwButton 'パスワードをコピー (Enter)'
        $btnPw.Font = New-Object System.Drawing.Font($ui.Font, [System.Drawing.FontStyle]::Bold)
        $btnPw.Add_Click({ Invoke-PwUi $ui { Copy-PwUiPassword $ui } })
        $copyBar.Controls.Add($btnPw)

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.Font = $ui.Font
        $mi = $menu.Items.Add('パスワードをコピー')
        $mi.Add_Click({ Invoke-PwUi $ui { Copy-PwUiPassword $ui } })

        foreach ($f in @($cfg.Fields)) {
            if ($f.Copy) {
                $b = New-PwButton "$($f.Label)をコピー"; $b.Tag = $f
                $b.Add_Click({ param($s) Invoke-PwUi $ui { Copy-PwUiField $ui $s.Tag } })
                $copyBar.Controls.Add($b)
                $mi = $menu.Items.Add("$($f.Label)をコピー"); $mi.Tag = $f
                $mi.Add_Click({ param($s) Invoke-PwUi $ui { Copy-PwUiField $ui $s.Tag } })
            }
        }
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($f in @($cfg.Fields)) {
            if ($f.Open) {
                $b = New-PwButton "$($f.Label)を開く"; $b.Tag = $f
                $b.Add_Click({ param($s) Invoke-PwUi $ui { Open-PwUiUrl $ui $s.Tag } })
                $copyBar.Controls.Add($b)
                $mi = $menu.Items.Add("$($f.Label)を開く"); $mi.Tag = $f
                $mi.Add_Click({ param($s) Invoke-PwUi $ui { Open-PwUiUrl $ui $s.Tag } })
            }
        }
        $mi = $menu.Items.Add('編集...');  $mi.Add_Click({ Invoke-PwUi $ui { Edit-PwUiEntry $ui } })
        $mi = $menu.Items.Add('削除...');  $mi.Add_Click({ Invoke-PwUi $ui { Remove-PwUiEntry $ui } })

        $grid = New-PwControl DataGridView @{
            Dock = 'Fill'; ReadOnly = $true; AllowUserToAddRows = $false; AllowUserToDeleteRows = $false
            AllowUserToResizeRows = $false; SelectionMode = 'FullRowSelect'; MultiSelect = $false; RowHeadersVisible = $false
            AutoSizeColumnsMode = 'Fill'; BorderStyle = 'None'; StandardTab = $true; ClipboardCopyMode = 'Disable'
            BackgroundColor = [System.Drawing.SystemColors]::Window
        }
        $ui.Grid = $grid
        $grid.ContextMenuStrip = $menu
        $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 250)
        [void]$grid.Columns.Add('__Title', 'タイトル');      $grid.Columns['__Title'].FillWeight = 150
        [void]$grid.Columns.Add('__Password', 'パスワード'); $grid.Columns['__Password'].FillWeight = 70
        foreach ($f in @($cfg.Fields)) { [void]$grid.Columns.Add($f.Name, $f.Label) }
        [void]$grid.Columns.Add('__Updated', '更新日時');    $grid.Columns['__Updated'].FillWeight = 90

        $statusStrip = New-Object System.Windows.Forms.StatusStrip
        $ui.Status    = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ Spring = $true; TextAlign = 'MiddleLeft' }
        $ui.ClipLabel = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ ForeColor = [System.Drawing.Color]::DarkOrange }
        $ui.Count     = New-Object System.Windows.Forms.ToolStripStatusLabel
        $statusStrip.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($ui.Status, $ui.ClipLabel, $ui.Count))

        # Dock は後から追加したものほど外側になる
        $form.Controls.AddRange([System.Windows.Forms.Control[]]@($grid, $copyBar, $top, $statusStrip))
        $ui.Panels = @($top, $copyBar, $grid)

        # ---- イベント ----
        $search.Add_TextChanged({ $ui.LastActivity = Get-Date; Update-PwGrid $ui })
        $search.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Copy-PwUiPassword $ui } }
            elseif ($e.KeyCode -eq 'Down' -and $grid.Rows.Count -gt 0) { $e.SuppressKeyPress = $true; [void]$grid.Focus() }
            elseif ($e.KeyCode -eq 'Escape') { $e.SuppressKeyPress = $true; $search.Clear() }
        })
        $catBox.Add_SelectedIndexChanged({ Update-PwGrid $ui })

        $grid.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq 'Enter') { $e.Handled = $true; $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Copy-PwUiPassword $ui } }
            elseif ($e.Control -and $e.KeyCode -eq 'C') {
                $e.Handled = $true; $e.SuppressKeyPress = $true
                if ($grid.CurrentCell) { Invoke-PwUi $ui { Copy-PwUiColumn $ui $grid.Columns[$grid.CurrentCell.ColumnIndex].Name } }
            }
            elseif ($e.KeyCode -eq 'Delete') { $e.Handled = $true; Invoke-PwUi $ui { Remove-PwUiEntry $ui } }
        })
        $grid.Add_CellDoubleClick({
            param($s, $e)
            if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
            $col = $grid.Columns[$e.ColumnIndex].Name
            if ($col -eq '__Title') { Invoke-PwUi $ui { Edit-PwUiEntry $ui } }
            else { Invoke-PwUi $ui { Copy-PwUiColumn $ui $col } }
        })
        $grid.Add_CellMouseDown({
            param($s, $e)
            $ui.LastActivity = Get-Date
            if ($e.Button -eq 'Right' -and $e.RowIndex -ge 0) {
                $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[[Math]::Max(0, $e.ColumnIndex)]
            }
        })
        $grid.Add_MouseMove({ $ui.LastActivity = Get-Date })
        $menu.Add_Opening({ param($s, $e) if (-not $grid.CurrentRow) { $e.Cancel = $true } })

        $btnNew.Add_Click({ Invoke-PwUi $ui { New-PwUiEntry $ui } })
        $btnEdit.Add_Click({ Invoke-PwUi $ui { Edit-PwUiEntry $ui } })
        $btnDel.Add_Click({ Invoke-PwUi $ui { Remove-PwUiEntry $ui } })
        $btnReload.Add_Click({ Invoke-PwUi $ui { Update-PwUiData $ui; Set-PwUiStatus $ui '再読込しました。' } })
        $btnBackup.Add_Click({ Invoke-PwUi $ui { Invoke-PwUiBackup $ui } })
        $btnConfig.Add_Click({
            Invoke-PwUi $ui {
                Edit-PwConfig
                Show-PwMessage "設定ファイルをメモ帳で開きました。`n保存したあと、PwManager を開き直すと反映されます。"
            }
        })
        $btnLock.Add_Click({ Invoke-PwUi $ui { Lock-PwUi $ui } })

        $form.Add_KeyDown({
            param($s, $e)
            $ui.LastActivity = Get-Date
            if ($e.Control -and $e.KeyCode -eq 'F') { $e.SuppressKeyPress = $true; [void]$search.Focus(); $search.SelectAll() }
            elseif ($e.Control -and $e.KeyCode -eq 'N') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { New-PwUiEntry $ui } }
            elseif ($e.Control -and $e.KeyCode -eq 'L') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Lock-PwUi $ui } }
            elseif ($e.KeyCode -eq 'F2') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Edit-PwUiEntry $ui } }
            elseif ($e.KeyCode -eq 'F5') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Update-PwUiData $ui } }
        })

        # 1秒ごと: クリップボード消去のカウントダウンと、無操作時の自動ロック
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.Add_Tick({
            if ($ui.ClipExpire) {
                $left = [int][Math]::Ceiling(($ui.ClipExpire - (Get-Date)).TotalSeconds)
                if ($left -le 0) {
                    if (Clear-PwClipboardIfMatch $ui.ClipSeq $ui.ClipHash) { Set-PwUiStatus $ui 'クリップボードを消去しました。' }
                    $ui.ClipSeq = $null; $ui.ClipHash = $null; $ui.ClipExpire = $null; $ui.ClipLabel.Text = ''
                } else {
                    $ui.ClipLabel.Text = "クリップボード消去まで $left 秒"
                }
            }
            $lockMin = [double]$ui.Cfg.AutoLockMinutes
            if ($lockMin -gt 0 -and -not $ui.Locking -and ((Get-Date) - $ui.LastActivity).TotalMinutes -ge $lockMin) {
                Invoke-PwUi $ui { Lock-PwUi $ui }
            }
        })

        $form.Add_Shown({
            Invoke-PwUi $ui {
                Update-PwUiData $ui
                Set-PwUiStatus $ui 'Enter: パスワードをコピー / ダブルクリック: その列をコピー / 右クリック: メニュー'
                Invoke-PwUiStartupBackup $ui
            }
            [void]$search.Focus()
            $timer.Start()
        })
        $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

        [void]$form.ShowDialog()
    } finally {
        $script:PinnedConfig = $null
        if ($ui -and $ui.ClipHash) { [void](Clear-PwClipboardIfMatch $ui.ClipSeq $ui.ClipHash) }
        if ($form) { $form.Dispose() }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

#endregion
