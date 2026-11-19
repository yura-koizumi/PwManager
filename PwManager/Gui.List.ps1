# Gui.List.ps1 - 一覧の画面側（List.ps1 のデータを、グリッド・検索欄・カテゴリ欄に結び付ける）
# （PwManager.psm1 から読み込まれる）

function Get-PwUiSelectedName($ui) {
    $r = $ui.Grid.CurrentRow
    if ($r -and $r.DataBoundItem) { [string]$r.DataBoundItem['__Name'] }
}

function Get-PwUiSelectedQuiet($ui) {
    Get-PwListEntry $ui.List (Get-PwUiSelectedName $ui)
}

function Get-PwUiSelected($ui) {
    $e = Get-PwUiSelectedQuiet $ui
    if (-not $e) { Set-PwUiStatus $ui '行を選択してください。' -Warn }
    $e
}

function Update-PwUiCategories($ui) {
    if (-not $ui.CategoryField) { return }
    $cb = $ui.Category
    $cur = [string]$cb.SelectedItem
    $ui.Suspend = $true
    try {
        $cb.BeginUpdate(); $cb.Items.Clear()
        [void]$cb.Items.Add('(すべて)')
        $cb.Items.AddRange([object[]](Get-PwListValues $ui.List $ui.CategoryField.Name $ui.Cfg.Categories))
        $cb.EndUpdate()
        $idx = $cb.Items.IndexOf($cur)
        $cb.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    } finally { $ui.Suspend = $false }
}

function Update-PwGrid($ui) {
    # 検索欄・カテゴリ欄の内容で絞り込み、選んでいた行（または $ui.SelectName の行）を選び直す
    if ($ui.Suspend) { return }
    $g = $ui.Grid
    $target = if ($ui.SelectName) { $ui.SelectName } else { Get-PwUiSelectedName $ui }
    $ui.SelectName = $null
    $cat = if ($ui.CategoryField -and $ui.Category.SelectedIndex -gt 0) { [string]$ui.Category.SelectedItem } else { '' }
    Set-PwListFilter $ui.List $ui.Search.Text $cat

    $count = $ui.List.View.Count
    if ($count -gt 0) {
        $idx = [Math]::Max(0, (Find-PwListIndex $ui.List $target))
        if (-not $g.CurrentRow -or $g.CurrentRow.Index -ne $idx) { $g.CurrentCell = $g.Rows[$idx].Cells['__Title'] }
    }
    $ui.Count.Text = "$count / $($ui.List.Table.Rows.Count) 件"
}

function Set-PwUiListData($ui, $Infos) {
    Import-PwListData $ui.List $Infos
    $ui.Grid.DataSource = $ui.List.View
}

function Update-PwUiData($ui) {
    # 全件の読み込み（起動時）
    $ui.Form.UseWaitCursor = $true
    try {
        if (-not $ui.SelectName) { $ui.SelectName = Get-PwUiSelectedName $ui }
        Set-PwUiListData $ui @(Invoke-PwVault $ui { Get-PwSecretInfo })
        Update-PwUiCategories $ui
        Update-PwGrid $ui
    } finally { $ui.Form.UseWaitCursor = $false }
}

function Update-PwUiAfterChange($ui, [string]$Name, [switch]$Removed) {
    # 登録・編集・削除のあと: 全件を読み直さず、その 1 件だけを保管庫から読み直して入れ替える
    $info = if ($Removed) { @() } else { @(Invoke-PwVault $ui { Get-PwSecretInfo $Name }) }
    if ($info.Count -gt 0) { Set-PwListRow $ui.List $info[0]; $ui.SelectName = $Name }
    else { Remove-PwListRow $ui.List $Name }
    Update-PwUiCategories $ui
    Update-PwGrid $ui
}
