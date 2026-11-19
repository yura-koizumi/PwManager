# Gui.Main.ps1 - メイン画面（Show-PwManager）
# （PwManager.psm1 から読み込まれる）

function New-PwUiState($Cfg) {
    <# 画面の状態（各関数に $ui として渡す）。項目はここで定義したものだけで、
       定義していない名前に書き込むとエラーになる（打ち間違いを防ぐため）。項目を足すときはここに追加する。 #>
    [pscustomobject]@{
        # 設定とデータ
        Cfg           = $Cfg                     # 起動時に読んだ設定（表示中は変わらない）
        CategoryField = @($Cfg.Fields | Where-Object { $_.Type -eq 'Category' }) | Select-Object -First 1   # 絞り込みに使う項目（無ければ $null）
        List          = New-PwList $Cfg          # 一覧のデータ（List.ps1）
        # 画面の部品（Show-PwManager で作る）
        Form          = $null                    # メイン画面
        Font          = New-Object System.Drawing.Font('Yu Gothic UI', 10)
        Search        = $null                    # 検索欄
        Category      = $null                    # カテゴリの絞り込み欄
        Grid          = $null                    # 一覧
        Status        = $null                    # 状態表示（左下）
        ClipLabel     = $null                    # クリップボード消去までの秒数
        Count         = $null                    # 件数表示
        # 動作の状態
        Suspend       = $false                   # $true の間は一覧を更新しない（カテゴリ欄の作り直し中など）
        SelectName    = $null                    # 次の一覧更新で選ぶ行（シークレット名）
        ClipSeq       = $null                    # コピーしたときのクリップボードの番号（自動消去の判定用）
        ClipHash      = $null                    # コピーした内容のハッシュ（自動消去の判定用）
        ClipExpire    = $null                    # クリップボードを消去する時刻
        LastActivity  = Get-Date                 # 最後に操作した時刻（自動ロックの判定用）
        UnlockedAt    = $null                    # 最後にロックを解除した時刻（再入力の判定用）
        Locking       = $false                   # ロック処理中（画面を閉じている途中）
    }
}

function Show-PwManager {
    <#
    .SYNOPSIS
      パスワード管理の画面を開く（Show-PwManager の別名が pwm）。
    .DESCRIPTION
      ロック（Ctrl+L・自動ロック）すると、メモリーに鍵やパスワードを残さないよう、画面を閉じてこのプロセスを終える。
      -RelaunchOnLock（ショートカットから起動したとき）なら、新しいプロセスでロック解除の画面を出し直す。
    .PARAMETER RelaunchOnLock
      ロックしたら、新しいプロセスで起動し直す（ショートカットから起動したとき用）。
    .PARAMETER Locked
      ロックから起動し直したところとして、ロック解除の画面に「ロックしました」と表示する。
    .EXAMPLE
      pwm
    #>
    [CmdletBinding()]
    param(
        [switch]$RelaunchOnLock,   # ロックしたら、新しいプロセスで起動し直す
        [switch]$Locked            # ロックから起動し直したところ（ロック解除の画面の文言を変える）
    )
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
        $ui = New-PwUiState $cfg

        $prompt = if ($Locked) { 'ロックしました。続けるにはマスターパスワードを入力してください。' } else { 'マスターパスワードを入力してください。' }
        if (-not (Show-PwUnlockDialog $ui $prompt)) { return }

        # ---- 画面の組み立て ----
        $form = New-PwControl Form @{
            Text = "PwManager - $env:USERNAME"; StartPosition = 'CenterScreen'
            Size = (New-PwSize 1240 680); MinimumSize = (New-PwSize 720 400); Font = $ui.Font; KeyPreview = $true
        }
        $ui.Form = $form

        # 上の帯: 検索欄と、ボタンは「＋ 新規」「≡（メニュー）」の 2 つだけ。行ごとの操作は Enter・ダブルクリック・右クリックで行う
        $top = New-PwControl FlowLayoutPanel @{ Dock = 'Top'; AutoSize = $true; WrapContents = $false; Padding = (New-PwPadding 6 6 6 4) }
        $search = New-PwControl TextBox @{ Width = 360 }
        $ui.Search = $search
        $top.Controls.Add((New-PwControl Label @{ Text = '検索'; AutoSize = $true; Margin = (New-PwPadding 3 8 3 3) }))
        $top.Controls.Add($search)
        $catBox = New-PwControl ComboBox @{ DropDownStyle = 'DropDownList'; Width = 160 }
        $ui.Category = $catBox
        if ($ui.CategoryField) {
            $top.Controls.Add((New-PwControl Label @{ Text = $ui.CategoryField.Label; AutoSize = $true; Margin = (New-PwPadding 12 8 3 3) }))
            $top.Controls.Add($catBox)
        }
        $btnNew  = New-PwButton '＋ 新規'
        $btnNew.Margin = New-PwPadding 12 3 3 3
        $btnMenu = New-PwButton '≡'   # Tag にメニューを持たせる（テストから探せるように）
        $btnMenu.Font = New-Object System.Drawing.Font($ui.Font.FontFamily, 12)
        $top.Controls.AddRange([System.Windows.Forms.Control[]]@($btnNew, $btnMenu))
        $tips = New-Object System.Windows.Forms.ToolTip
        $tips.SetToolTip($btnNew, '新規登録 (Ctrl+N)')
        $tips.SetToolTip($btnMenu, 'メニュー')

        # ≡ のメニュー: 毎日は使わない操作
        $appMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $appMenu.Font = $ui.Font
        $addItem = {
            param($Menu, [string]$Text, [string]$Keys, [scriptblock]$Action)
            $item = $Menu.Items.Add($Text)
            if ($Keys) { $item.ShortcutKeyDisplayString = $Keys }
            $item.Tag = $Action
            $item.Add_Click({ param($s) Invoke-PwUi $ui $s.Tag })
        }
        & $addItem $appMenu 'バックアップ' '' { Invoke-PwUiBackup $ui }
        & $addItem $appMenu 'マスターパスワードの変更...' '' { Invoke-PwUiChangePassword $ui }
        & $addItem $appMenu '設定ファイルを開く...' '' { Invoke-PwUiConfig $ui }
        [void]$appMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        & $addItem $appMenu 'ロック' 'Ctrl+L' { Lock-PwUi $ui }
        $btnMenu.Tag = $appMenu

        # 右クリックのメニュー: 選んだ行への操作
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.Font = $ui.Font
        & $addItem $menu 'パスワードをコピー' 'Enter' { Copy-PwUiPassword $ui }
        foreach ($f in @($cfg.Fields)) {
            if (-not $f.Copy) { continue }
            $item = $menu.Items.Add("$($f.Label)をコピー"); $item.Tag = $f
            $item.Add_Click({ param($s) Invoke-PwUi $ui { Copy-PwUiField $ui $s.Tag } })
        }
        foreach ($f in @($cfg.Fields)) {
            if (-not $f.Open) { continue }
            $item = $menu.Items.Add("$($f.Label)を開く"); $item.Tag = $f
            $item.Add_Click({ param($s) Invoke-PwUi $ui { Open-PwUiUrl $ui $s.Tag } })
        }
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        & $addItem $menu '編集...' 'F2' { Edit-PwUiEntry $ui }
        & $addItem $menu '削除...' 'Del' { Remove-PwUiEntry $ui }

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
        $grid.DataSource = $ui.List.View

        $statusStrip = New-Object System.Windows.Forms.StatusStrip
        $ui.Status    = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ Spring = $true; TextAlign = 'MiddleLeft' }
        $ui.ClipLabel = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ ForeColor = [System.Drawing.Color]::DarkOrange }
        $ui.Count     = New-Object System.Windows.Forms.ToolStripStatusLabel
        $statusStrip.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($ui.Status, $ui.ClipLabel, $ui.Count))

        # Dock は後から追加したものほど外側になる
        $form.Controls.AddRange([System.Windows.Forms.Control[]]@($grid, $top, $statusStrip))
        Register-PwActivity $ui $form

        # ---- イベント ----
        # 操作ありの記録は Register-PwActivity（キー入力・クリック）でまとめて行う
        $search.Add_TextChanged({ Invoke-PwUi $ui { Update-PwGrid $ui } })
        $search.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Copy-PwUiPassword $ui } }
            elseif ($e.KeyCode -eq 'Down' -and $grid.Rows.Count -gt 0) { $e.SuppressKeyPress = $true; [void]$grid.Focus() }
            elseif ($e.KeyCode -eq 'Escape') { $e.SuppressKeyPress = $true; $search.Clear() }
        })
        $catBox.Add_SelectedIndexChanged({ Invoke-PwUi $ui { Update-PwGrid $ui } })

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
        $btnMenu.Add_Click({ $appMenu.Show($btnMenu, 0, $btnMenu.Height) })

        $form.Add_KeyDown({
            param($s, $e)
            if ($e.Control -and $e.KeyCode -eq 'F') { $e.SuppressKeyPress = $true; [void]$search.Focus(); $search.SelectAll() }
            elseif ($e.Control -and $e.KeyCode -eq 'N') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { New-PwUiEntry $ui } }
            elseif ($e.Control -and $e.KeyCode -eq 'L') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Lock-PwUi $ui } }
            elseif ($e.KeyCode -eq 'F2') { $e.SuppressKeyPress = $true; Invoke-PwUi $ui { Edit-PwUiEntry $ui } }
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
    if ($ui -and $ui.Locking) {
        # ロックで閉じた。このプロセスはここで終わる（呼び出し元が PowerShell を終了する）
        if ($RelaunchOnLock) { Start-PwLauncher -Locked }
        else { Write-Host 'ロックしました。開き直すには pwm を実行してください。' }
    }
}

