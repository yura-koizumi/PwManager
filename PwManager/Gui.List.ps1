# Gui.List.ps1 - 一覧（DataTable）の作成・絞り込み・1 行単位の更新
# （PwManager.psm1 から読み込まれる）

# 一覧は DataTable に入れて DataGridView に結び付ける。絞り込み（RowFilter）・描画・見出しクリックでの
# 並べ替えはすべて .NET の中で行われ、PowerShell の処理が走るのは読み込み時と入力時だけ。
# 行は保管庫のメタデータから直接作り、エントリのオブジェクトは選んだ行の分だけ作る。
# 登録・編集・削除のあとは、全件を読み直さずにその 1 行だけを入れ替える。
#   $ui.Table  : 列は __Name, __Title, 各項目, __Updated, __Password, __Hay(検索用), __Cat(絞り込み用)
#   $ui.View   : $ui.Table の DataView。グリッドはこれを表示する
#   $ui.ByName : シークレット名 → @{ Meta = メタデータ; Row = DataRow }

$script:PwSpaceChars = [char[]]@(' ', "`t", [char]0x3000)   # 検索語の区切り（全角スペースも含む）
$script:PwFind = [System.ComponentModel.IBindingList].GetMethod('Find')

function Initialize-PwUiColumns($ui) {
    $ui.FieldNames = [string[]]@(foreach ($f in $ui.Cfg.Fields) { $f.Name })
    $ui.RowKeys    = [string[]](@('Title') + $ui.FieldNames + @('Updated'))   # 表の 2 列目から順に入れる値
    $ui.EntryKeys  = Get-PwEntryKeys $ui.Cfg
    $ui.CatIndex   = if ($ui.CategoryField) { 2 + [Array]::IndexOf($ui.FieldNames, $ui.CategoryField.Name) } else { $null }
}

function Add-PwUiRows($ui, $Table, $Infos) {
    # 件数が多くても速いよう、関数呼び出しやオブジェクトの生成をせずに 1 回のループで組み立てる
    # （Metadata は読み取り専用の辞書で、無いキーを引くと例外になるため ContainsKey で確かめる）
    $keys = $ui.RowKeys; $nk = $keys.Length; $last = $nk - 1; $ci = $ui.CatIndex; $by = $ui.ByName
    foreach ($info in $Infos) {
        $m = $info.Metadata
        $row = [object[]]::new($nk + 4)
        $row[0] = $info.Name
        $hay = ''
        for ($i = 0; $i -lt $nk; $i++) {
            $k = $keys[$i]
            $v = if ($m -and $m.ContainsKey($k)) { [string]$m[$k] } else { '' }
            if ($i -lt $last) { $hay += "`n" + $v }   # 検索対象はタイトルと各項目（更新日時は除く）
            $row[$i + 1] = $v.Replace("`r`n", ' ').Replace("`n", ' ')
        }
        $row[$nk + 1] = '••••••••'
        $row[$nk + 2] = $hay
        $row[$nk + 3] = if ($ci) { $row[$ci] } else { '' }
        $by[$info.Name] = @{ Meta = $m; Row = $Table.Rows.Add($row) }
    }
}

function Import-PwUiTable($ui, $Infos) {
    # 新しい表をグリッドから切り離した状態で作り、最後に差し替える
    # （結び付いたまま行を足すと、1 行ごとにグリッドの更新が走って遅くなる）
    $t = New-Object System.Data.DataTable
    $t.Locale = [Globalization.CultureInfo]::CurrentCulture
    $t.CaseSensitive = $false   # 大文字小文字・全角半角・ひらがなカタカナを区別せずに比べる
    foreach ($c in @('__Name', '__Title') + $ui.FieldNames + @('__Updated', '__Password', '__Hay', '__Cat')) {
        [void]$t.Columns.Add($c, [string])
    }
    $ui.ByName = @{}
    $t.BeginLoadData()
    Add-PwUiRows $ui $t $Infos
    $t.EndLoadData()

    # 絞り込みと並べ替えの状態は引き継ぐ（初回はタイトル順）
    $old = $ui.View
    $view = if ($old) { New-Object System.Data.DataView($t, $old.RowFilter, $old.Sort, 'CurrentRows') }
            else { New-Object System.Data.DataView($t, '', '__Title', 'CurrentRows') }
    $ui.Table = $t
    $ui.View = $view
    $ui.NameProp = ([System.ComponentModel.ITypedList]$view).GetItemProperties($null)['__Name']
    $ui.Grid.DataSource = $view
}

function Update-PwUiRow($ui, [string]$Name) {
    # 1 件だけ保管庫から読み直して、その行を入れ替える（無くなっていれば消す）
    $info = @(Invoke-PwVault $ui { Get-PwSecretInfo $Name })
    Remove-PwUiRow $ui $Name
    if ($info.Count -gt 0) { Add-PwUiRows $ui $ui.Table $info }
}

function Remove-PwUiRow($ui, [string]$Name) {
    $item = $ui.ByName[$Name]
    if ($item) { $ui.Table.Rows.Remove($item.Row); $ui.ByName.Remove($Name) }
}

function Get-PwUiSelectedName($ui) {
    $r = $ui.Grid.CurrentRow
    if ($r -and $r.DataBoundItem) { [string]$r.DataBoundItem['__Name'] }
}

function Get-PwUiSelectedQuiet($ui) {
    $name = Get-PwUiSelectedName $ui
    $item = if ($name) { $ui.ByName[$name] }
    if ($item) { ConvertTo-PwEntry $name $item.Meta $ui.EntryKeys }
}

function Get-PwUiSelected($ui) {
    $e = Get-PwUiSelectedQuiet $ui
    if (-not $e) { Set-PwUiStatus $ui '行を選択してください。' -Warn }
    $e
}

function Get-PwUiCategoryList($ui, [string]$FieldName) {
    # 設定の候補 → 登録済みの値 の順に、重複と空を除いて返す
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($ui.Cfg.Categories)) { $s = [string]$c; if ($s -and $seen.Add($s)) { $list.Add($s) } }
    foreach ($item in $ui.ByName.Values) {
        $m = $item.Meta
        if ($m -and $m.ContainsKey($FieldName)) { $s = [string]$m[$FieldName]; if ($s -and $seen.Add($s)) { $list.Add($s) } }
    }
    , $list.ToArray()
}

function Update-PwUiCategories($ui) {
    if (-not $ui.CategoryField) { return }
    $cb = $ui.Category
    $cur = [string]$cb.SelectedItem
    $ui.Suspend = $true
    try {
        $cb.BeginUpdate(); $cb.Items.Clear()
        [void]$cb.Items.Add('(すべて)')
        $cb.Items.AddRange([object[]](Get-PwUiCategoryList $ui $ui.CategoryField.Name))
        $cb.EndUpdate()
        $idx = $cb.Items.IndexOf($cur)
        $cb.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    } finally { $ui.Suspend = $false }
}

function ConvertTo-PwLikeText([string]$s) {
    # RowFilter の LIKE で特別な意味を持つ文字を、文字そのものとして扱わせる
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '*' -or $ch -eq '%' -or $ch -eq '[' -or $ch -eq ']') { [void]$sb.Append('[').Append($ch).Append(']') }
        elseif ($ch -eq "'") { [void]$sb.Append("''") }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

function Update-PwGrid($ui) {
    if ($ui.Suspend) { return }
    $g = $ui.Grid
    $target = if ($ui.SelectName) { $ui.SelectName } else { Get-PwUiSelectedName $ui }
    $ui.SelectName = $null

    # 空白区切りの全単語がタイトルまたはいずれかの項目に含まれる行だけを表示する
    $conds = New-Object System.Collections.Generic.List[string]
    foreach ($w in $ui.Search.Text.Split($script:PwSpaceChars, [StringSplitOptions]::RemoveEmptyEntries)) {
        $conds.Add("__Hay LIKE '%" + (ConvertTo-PwLikeText $w) + "%'")
    }
    if ($ui.CategoryField -and $ui.Category.SelectedIndex -gt 0) {
        $conds.Add("__Cat = '" + ([string]$ui.Category.SelectedItem).Replace("'", "''") + "'")
    }
    $filter = $conds -join ' AND '
    if ($ui.View.RowFilter -ne $filter) { $ui.View.RowFilter = $filter }

    $count = $ui.View.Count
    if ($count -gt 0) {
        $idx = if ($target) { [int]$script:PwFind.Invoke($ui.View, @($ui.NameProp, $target)) } else { -1 }
        if ($idx -lt 0) { $idx = 0 }
        if (-not $g.CurrentRow -or $g.CurrentRow.Index -ne $idx) { $g.CurrentCell = $g.Rows[$idx].Cells['__Title'] }
    }
    $ui.Count.Text = "$count / $($ui.Table.Rows.Count) 件"
}

function Update-PwUiData($ui) {
    # 全件の読み直し（起動時・ロック解除時・F5）
    $ui.Form.UseWaitCursor = $true
    try {
        if (-not $ui.SelectName) { $ui.SelectName = Get-PwUiSelectedName $ui }
        Import-PwUiTable $ui @(Invoke-PwVault $ui { Get-PwSecretInfo })
        Update-PwUiCategories $ui
        Update-PwGrid $ui
    } finally { $ui.Form.UseWaitCursor = $false }
}

function Update-PwUiAfterChange($ui, [string]$Name, [switch]$Removed) {
    # 登録・編集・削除のあと: その 1 行だけを入れ替える
    if ($Removed) { Remove-PwUiRow $ui $Name } else { Update-PwUiRow $ui $Name; $ui.SelectName = $Name }
    Update-PwUiCategories $ui
    Update-PwGrid $ui
}
