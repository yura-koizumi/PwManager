# Gui.Dialogs.ps1 - 画面の共通部品とダイアログ（ロック解除・登録/編集）
# （PwManager.psm1 から読み込まれる）

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
    # ロックで閉じている途中は表示しない（子画面を閉じたことによる「キャンセル」などで、閉じるのを止めないように）
    try { & $Action } catch { if (-not $ui.Locking) { Show-PwMessage $_.Exception.Message 'Error' } }
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

function Register-PwActivity($ui, $Form) {
    # 画面（子コントロールを含む）でのキー入力・クリックを「操作あり」として自動ロックの判定に使う
    $touch = { $ui.LastActivity = Get-Date }.GetNewClosure()
    $Form.KeyPreview = $true
    $Form.Add_KeyDown($touch)
    $stack = New-Object System.Collections.Stack
    $stack.Push($Form)
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        $c.Add_MouseDown($touch)
        foreach ($child in $c.Controls) { $stack.Push($child) }
    }
}

function Set-PwUiStatus($ui, [string]$Text, [switch]$Warn) {
    $ui.Status.Text = $Text
    $ui.Status.ForeColor = if ($Warn) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.SystemColors]::ControlText }
}

function Show-PwUnlockDialog($ui, [string]$Message = 'マスターパスワードを入力してください。') {
    $dlg = New-PwControl Form @{
        Text = 'PwManager - ロック解除'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        Font = $ui.Font; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = (New-PwPadding 12); TopMost = $true
        Tag = 'PwUnlock'   # 自動ロックの判定で、この画面は閉じない
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

    # この画面を開く前の失敗（本人以外が試した可能性がある）。この画面での打ち間違いは含めない
    $prior = Get-PwUnlockFailures
    $state = @{ Ok = $false; Tries = 0; Prior = $prior.Count; Last = $prior.Last }
    $ok.Add_Click({
        if (-not $tb.Text) { return }
        $left = Get-PwUnlockRemaining
        if ($left -gt 0) {
            # 続けて失敗したあとの待ち時間中は、試さない（回数も増やさない）
            $tb.Clear()
            $err.Text = "パスワードの入力に続けて失敗したため、あと $left 秒待ってから入力してください。"
            return
        }
        $sec = ConvertTo-SecureString $tb.Text -AsPlainText -Force
        $tb.Clear()
        $dlg.UseWaitCursor = $true
        try {
            [void](Invoke-PwUnlock $sec)
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
    $dlg.Add_FormClosing({ $tb.Clear() })   # キャンセルで閉じたときも、入力欄に残さない

    if ($ui.Form -and $ui.Form.Visible) {
        $dlg.StartPosition = 'CenterParent'; [void]$dlg.ShowDialog($ui.Form)
    } else {
        $dlg.StartPosition = 'CenterScreen'; [void]$dlg.ShowDialog()
    }
    $dlg.Dispose()
    if ($state.Ok -and $state.Prior -gt 0) {
        $when = if ($state.Last) { $state.Last.ToString('yyyy/MM/dd HH:mm') } else { '不明' }
        $text = ("前回正しく開いてから、マスターパスワードの入力に {0} 回失敗しています（最後: {1}）。`n" +
                 "心当たりがなければ、≡ →「マスターパスワードの変更」で変更することを検討してください。") -f $state.Prior, $when
        Show-PwMessage $text 'Warn'
    }
    $state.Ok
}

function Show-PwChangePasswordDialog($ui) {
    # マスターパスワードを変更する。変更したら Set-PwMasterPassword の結果を、キャンセルなら $null を返す
    $dlg = New-PwControl Form @{
        Text = 'マスターパスワードの変更'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        ShowInTaskbar = $false; StartPosition = 'CenterParent'; Font = $ui.Font; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'
        Padding = (New-PwPadding 12)
    }
    $t = New-PwControl TableLayoutPanel @{ ColumnCount = 2; AutoSize = $true; Dock = 'Fill' }
    $boxes = @{}
    $r = 0
    foreach ($k in 'Current', 'New', 'Confirm') {
        $label = switch ($k) { 'Current' { '今のパスワード' } 'New' { '新しいパスワード' } 'Confirm' { '新しいパスワード（確認）' } }
        $t.Controls.Add((New-PwControl Label @{ Text = $label; AutoSize = $true; Margin = (New-PwPadding 3 7 10 3) }), 0, $r)
        $boxes[$k] = New-PwControl TextBox @{ Width = 300; UseSystemPasswordChar = $true }
        $t.Controls.Add($boxes[$k], 1, $r)
        $r++
    }
    $hint = New-PwControl Label @{
        AutoSize = $true; MaximumSize = (New-PwSize 300 0); ForeColor = [System.Drawing.SystemColors]::GrayText
        Text = "$($script:MasterPasswordMinLength) 文字以上で、ほかでは使っていないもの。保存済みのデータもバックアップも、そのまま使えます。"
    }
    $t.Controls.Add($hint, 1, $r); $r++
    $err = New-PwControl Label @{ AutoSize = $true; ForeColor = [System.Drawing.Color]::Firebrick; MaximumSize = (New-PwSize 300 0) }
    $t.Controls.Add($err, 1, $r); $r++
    $btns   = New-PwControl FlowLayoutPanel @{ FlowDirection = 'RightToLeft'; AutoSize = $true; Dock = 'Fill'; Margin = (New-PwPadding 0 8 0 0) }
    $cancel = New-PwButton 'キャンセル'; $cancel.DialogResult = 'Cancel'
    $ok     = New-PwButton '変更する'
    $btns.Controls.AddRange([System.Windows.Forms.Control[]]@($cancel, $ok))
    $t.Controls.Add($btns, 1, $r)
    $dlg.Controls.Add($t)
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    $state = @{ Result = $null }
    $ok.Add_Click({
        if (-not $boxes['Current'].Text) { $err.Text = '今のパスワードを入力してください。'; return }
        if (-not $boxes['New'].Text) { $err.Text = '新しいパスワードを入力してください。'; return }
        $sec = @{}
        foreach ($k in $boxes.Keys) {
            # 確認欄が空でも比較できるよう、空のときは空の SecureString にする
            $sec[$k] = if ($boxes[$k].Text) { ConvertTo-SecureString $boxes[$k].Text -AsPlainText -Force } else { New-Object System.Security.SecureString }
        }
        $problem = Test-PwMasterPasswordRule $sec['New'] $sec['Confirm'] $sec['Current']
        if ($problem) { $err.Text = $problem; return }
        $dlg.UseWaitCursor = $true
        try {
            $state.Result = Set-PwMasterPassword -Current $sec['Current'] -New $sec['New'] -Confirm:$false
            $dlg.Close()
        } catch {
            $err.Text = $_.Exception.Message
        } finally {
            $dlg.UseWaitCursor = $false
            foreach ($b in $boxes.Values) { $b.Clear() }
            [void]$boxes['Current'].Focus()
        }
    })
    $dlg.Add_Shown({ [void]$boxes['Current'].Focus() })
    $dlg.Add_FormClosing({ foreach ($b in $boxes.Values) { $b.Clear() } })   # キャンセルで閉じたときも、入力欄に残さない
    Register-PwActivity $ui $dlg
    [void]$dlg.ShowDialog($ui.Form)
    $dlg.Dispose()
    $state.Result
}

function Show-PwEditDialog($ui, $Entry, [switch]$Copy) {
    # 保存したらシークレット名を、キャンセルなら $null を返す。
    # -Copy は複製: $Entry の項目を入れた新規登録（パスワードは使い回さないよう引き継がない）
    $cfg = $ui.Cfg
    $isNew = -not $Entry -or $Copy
    $dlg = New-PwControl Form @{
        Text = $(if ($Copy) { "複製して登録 - $($Entry.Title)" } elseif ($isNew) { '新規登録' } else { "編集 - $($Entry.Title)" })
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

    $title = New-PwControl TextBox @{ Width = 440; Text = $(if ($Copy) { "$($Entry.Title) のコピー" } elseif ($Entry) { $Entry.Title } else { '' }) }
    & $addRow 'タイトル *' $title

    $inputs = @{}
    foreach ($f in @($cfg.Fields)) {
        $val = if ($Entry) { [string]$Entry.($f.Name) } else { '' }
        if ($f.Type -eq 'Category') {
            $c = New-PwControl ComboBox @{ Width = 440; DropDownStyle = 'DropDown' }
            $c.Items.AddRange([object[]](Get-PwListValues $ui.List $f.Name $cfg.Categories))
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

    # 「生成」の条件（サイトの決まりに合わせる）。前回の選択を、画面を閉じるまで覚えておく
    if (-not $ui.GenOptions) {
        $g = $cfg.PasswordGenerator
        $ui.GenOptions = @{ Length = [int]$g.Length; Kind = $(if ($g.Symbols) { 0 } else { 1 }) }
    }
    $genPanel = New-PwControl FlowLayoutPanel @{ AutoSize = $true; WrapContents = $false; Margin = (New-PwPadding 0) }
    $genLabel = New-PwControl Label @{ Text = '生成:'; AutoSize = $true; Margin = (New-PwPadding 3 7 3 3); ForeColor = [System.Drawing.SystemColors]::GrayText }
    $genLen = New-PwControl NumericUpDown @{ Width = 60; Minimum = $script:PasswordMinLength; Maximum = $script:PasswordMaxLength }
    $genLen.Value = [Math]::Min($script:PasswordMaxLength, [Math]::Max($script:PasswordMinLength, $ui.GenOptions.Length))
    $genLenLabel = New-PwControl Label @{ Text = '文字'; AutoSize = $true; Margin = (New-PwPadding 3 7 10 3) }
    $genKind = New-PwControl ComboBox @{ Width = 130; DropDownStyle = 'DropDownList' }
    $genKind.Items.AddRange([object[]]@('英数字と記号', '英数字のみ', '数字のみ'))
    $genKind.SelectedIndex = $ui.GenOptions.Kind
    $genPanel.Controls.AddRange([System.Windows.Forms.Control[]]@($genLabel, $genLen, $genLenLabel, $genKind))
    & $addRow '' $genPanel
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
    $gen.Add_Click({
        Invoke-PwUi $ui {
            $ui.GenOptions = @{ Length = [int]$genLen.Value; Kind = $genKind.SelectedIndex }
            $pw.Text = New-PwPassword -Length $ui.GenOptions.Length -NoSymbols:($genKind.SelectedIndex -eq 1) -DigitsOnly:($genKind.SelectedIndex -eq 2)
            $show.Checked = $true
        }
    })
    $save.Add_Click({
        Invoke-PwUi $ui {
            $tt = $title.Text.Trim()
            if (-not $tt) { Show-PwMessage 'タイトルを入力してください。' 'Warn'; [void]$title.Focus(); return }
            if ($isNew -and -not $pw.Text) { Show-PwMessage 'パスワードを入力してください（「生成」で自動作成もできます）。' 'Warn'; [void]$pw.Focus(); return }
            $fields = @{}
            foreach ($k in $inputs.Keys) { $fields[$k] = $inputs[$k].Text }
            $sec  = if ($pw.Text) { ConvertTo-SecureString $pw.Text -AsPlainText -Force } else { $null }
            $name = if ($Entry -and -not $Copy) { $Entry.Name } else { $null }
            $dlg.UseWaitCursor = $true
            try { $state.Saved = Invoke-PwVault $ui { Save-PwEntry -Name $name -Title $tt -Fields $fields -Password $sec } }
            finally { $dlg.UseWaitCursor = $false }
            $pw.Clear()
            $dlg.Close()
        }
    })
    $dlg.Add_Shown({ [void]$title.Focus(); $title.SelectAll() })   # 複製では「〇〇 のコピー」をすぐ打ち替えられるように
    $dlg.Add_FormClosing({ $pw.Clear() })   # キャンセルで閉じたときも、パスワード欄に残さない
    Register-PwActivity $ui $dlg

    [void]$dlg.ShowDialog($ui.Form)
    $dlg.Dispose()
    $state.Saved
}

