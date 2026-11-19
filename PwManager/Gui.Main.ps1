# Gui.Main.ps1 - メイン画面（Show-PwManager）
# （PwManager.psm1 から読み込まれる）


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

    $mutex = New-Object System.Threading.Mutex($false, $script:GuiMutexName)
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
            Cfg = $cfg; Form = $null; Suspend = $false; SelectName = $null
            Table = $null; View = $null; NameProp = $null; ByName = @{}
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
            AutoGenerateColumns = $false
        }
        # スクロール時のちらつきを抑える（DoubleBuffered は非公開プロパティ）
        $grid.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($grid, $true, $null)
        $ui.Grid = $grid
        $grid.ContextMenuStrip = $menu
        $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 250)
        [void]$grid.Columns.Add('__Title', 'タイトル');      $grid.Columns['__Title'].FillWeight = 150
        [void]$grid.Columns.Add('__Password', 'パスワード'); $grid.Columns['__Password'].FillWeight = 70
        foreach ($f in @($cfg.Fields)) { [void]$grid.Columns.Add($f.Name, $f.Label) }
        [void]$grid.Columns.Add('__Updated', '更新日時');    $grid.Columns['__Updated'].FillWeight = 90
        foreach ($col in $grid.Columns) { $col.DataPropertyName = $col.Name }   # 列名 = DataTable の列名
        $grid.Columns['__Password'].SortMode = 'NotSortable'
        Initialize-PwUiColumns $ui
        Import-PwUiTable $ui @()   # 空の表で列を結び付けておく

        $statusStrip = New-Object System.Windows.Forms.StatusStrip
        $ui.Status    = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ Spring = $true; TextAlign = 'MiddleLeft' }
        $ui.ClipLabel = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ ForeColor = [System.Drawing.Color]::DarkOrange }
        $ui.Count     = New-Object System.Windows.Forms.ToolStripStatusLabel
        $statusStrip.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($ui.Status, $ui.ClipLabel, $ui.Count))

        # Dock は後から追加したものほど外側になる
        $form.Controls.AddRange([System.Windows.Forms.Control[]]@($grid, $copyBar, $top, $statusStrip))
        $ui.Panels = @($top, $copyBar, $grid)
        Register-PwActivity $ui $form

        # ---- イベント ----
        # 操作ありの記録は Register-PwActivity（キー入力・クリック）でまとめて行う
        $search.Add_TextChanged({ Update-PwGrid $ui })
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
            if ($e.Button -eq 'Right' -and $e.RowIndex -ge 0) {
                $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[[Math]::Max(0, $e.ColumnIndex)]
            }
        })
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
            Invoke-PwUi $ui { Invoke-PwUiAutoLock $ui }
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

