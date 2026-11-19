# List.ps1 - 一覧のデータ（画面の部品には依存しない。tests\List.Tests.ps1 で検証）
# （PwManager.psm1 から読み込まれる）
#
# 一覧は DataTable に入れ、画面はその DataView をグリッドに結び付けて表示する。
# 絞り込み（RowFilter）・並べ替え・描画は .NET の中で行われるため、件数が多くても軽い。
# 行は保管庫のメタデータ（SecretInfo.Metadata）から直接作り、エントリのオブジェクトは必要な 1 件分だけ作る。
#
# 一覧の状態（New-PwList が返すオブジェクト）
#   Columns   : 表の列名。__Name, __Title, 各項目(Fields の Name), __Updated, __Password, __Hay, __Cat
#   RowKeys   : 表の 2 列目（__Title）から順に入れるメタデータのキー（Title, 各項目, Updated）
#   Table     : DataTable
#   View      : Table の DataView（絞り込み・並べ替えの状態を持つ）
#   ByName    : シークレット名 → @{ Meta = メタデータ; Row = DataRow }

$script:PwSpaceChars = [char[]]@(' ', "`t", [char]0x3000)   # 検索語の区切り（全角スペースも含む）
$script:PwFind = [System.ComponentModel.IBindingList].GetMethod('Find')
$script:PwMask = '••••••••'

function New-PwList($Cfg) {
    $fieldNames = [string[]]@(foreach ($f in $Cfg.Fields) { $f.Name })
    $catField = @($Cfg.Fields | Where-Object { $_.Type -eq 'Category' }) | Select-Object -First 1
    $columns = [string[]](@('__Name', '__Title') + $fieldNames + @('__Updated', '__Password', '__Hay', '__Cat'))
    $list = [pscustomobject]@{
        Columns   = $columns
        RowKeys   = [string[]](@('Title') + $fieldNames + @('Updated'))
        EntryKeys = Get-PwEntryKeys $Cfg
        CatField  = if ($catField) { $catField.Name } else { $null }
        PwIndex   = [Array]::IndexOf($columns, '__Password')
        HayIndex  = [Array]::IndexOf($columns, '__Hay')
        CatIndex  = [Array]::IndexOf($columns, '__Cat')
        CatSource = if ($catField) { [Array]::IndexOf($columns, $catField.Name) } else { -1 }
        Table     = $null
        View      = $null
        NameProp  = $null
        ByName    = @{}
    }
    Import-PwListData $list @()
    $list
}

function Add-PwListRows($List, $Table, $Infos) {
    # 件数が多くても速いよう、関数呼び出しやオブジェクトの生成をせずに 1 回のループで組み立てる
    # （Metadata は読み取り専用の辞書で、無いキーを引くと例外になるため ContainsKey で確かめる）
    $keys = $List.RowKeys; $nk = $keys.Length; $last = $nk - 1; $width = $List.Columns.Length
    $pw = $List.PwIndex; $hayAt = $List.HayIndex; $catAt = $List.CatIndex; $catFrom = $List.CatSource
    $by = $List.ByName
    foreach ($info in $Infos) {
        $m = $info.Metadata
        $row = [object[]]::new($width)
        $row[0] = $info.Name
        $hay = ''
        for ($i = 0; $i -lt $nk; $i++) {
            $k = $keys[$i]
            $v = if ($m -and $m.ContainsKey($k)) { [string]$m[$k] } else { '' }
            if ($i -lt $last) { $hay += "`n" + $v }   # 検索対象はタイトルと各項目（更新日時は除く）
            $row[$i + 1] = $v.Replace("`r`n", ' ').Replace("`n", ' ')   # 一覧では改行を空白にして 1 行で表示
        }
        $row[$pw] = $script:PwMask
        $row[$hayAt] = $hay
        $row[$catAt] = if ($catFrom -ge 0) { $row[$catFrom] } else { '' }
        $by[$info.Name] = @{ Meta = $m; Row = $Table.Rows.Add($row) }
    }
}

function Import-PwListData($List, $Infos) {
    # 全件を入れ直す。新しい表を作ってから差し替えるので、画面は DataSource を $List.View に付け替えること
    # （表示中の表に行を足すと、1 行ごとにグリッドの更新が走って遅くなる）
    $t = New-Object System.Data.DataTable
    $t.Locale = [Globalization.CultureInfo]::CurrentCulture
    $t.CaseSensitive = $false   # 大文字小文字・全角半角・ひらがなカタカナを区別せずに比べる
    foreach ($c in $List.Columns) { [void]$t.Columns.Add($c, [string]) }
    $List.ByName = @{}
    $t.BeginLoadData()
    Add-PwListRows $List $t $Infos
    $t.EndLoadData()

    # 絞り込みと並べ替えの状態は引き継ぐ（初回はタイトル順）
    $old = $List.View
    $List.View = if ($old) { New-Object System.Data.DataView($t, $old.RowFilter, $old.Sort, 'CurrentRows') }
                 else { New-Object System.Data.DataView($t, '', '__Title', 'CurrentRows') }
    $List.Table = $t
    $List.NameProp = ([System.ComponentModel.ITypedList]$List.View).GetItemProperties($null)['__Name']
}

function Set-PwListRow($List, $Info) {
    # 1 件を追加または入れ替える（表示中の表に対して行うので、画面の付け替えは不要）
    Remove-PwListRow $List $Info.Name
    Add-PwListRows $List $List.Table @($Info)
}

function Remove-PwListRow($List, [string]$Name) {
    $item = $List.ByName[$Name]
    if ($item) { $List.Table.Rows.Remove($item.Row); $List.ByName.Remove($Name) }
}

function Get-PwListEntry($List, [string]$Name) {
    $item = if ($Name) { $List.ByName[$Name] }
    if ($item) { ConvertTo-PwEntry $Name $item.Meta $List.EntryKeys }
}

function Get-PwListValues($List, [string]$FieldName, $Base) {
    # $Base（設定の候補）をその順で、続けて登録済みの値を並べ替えて返す（重複と空は除く）
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($Base)) { $s = [string]$c; if ($s -and $seen.Add($s)) { $out.Add($s) } }
    $extra = New-Object System.Collections.Generic.List[string]
    foreach ($item in $List.ByName.Values) {
        $m = $item.Meta
        if ($m -and $m.ContainsKey($FieldName)) { $s = [string]$m[$FieldName]; if ($s -and $seen.Add($s)) { $extra.Add($s) } }
    }
    $extra.Sort([StringComparer]::CurrentCulture)
    $out.AddRange($extra)
    , $out.ToArray()
}

function ConvertTo-PwLikeText([string]$Text) {
    # RowFilter の LIKE で特別な意味を持つ文字を、文字そのものとして扱わせる
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '*' -or $ch -eq '%' -or $ch -eq '[' -or $ch -eq ']') { [void]$sb.Append('[').Append($ch).Append(']') }
        elseif ($ch -eq "'") { [void]$sb.Append("''") }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

function Get-PwListFilter([string]$Text, [string]$Category) {
    # 空白区切りの全単語がタイトルまたはいずれかの項目に含まれ、カテゴリが一致する行（RowFilter の式）
    $conds = New-Object System.Collections.Generic.List[string]
    foreach ($w in $Text.Split($script:PwSpaceChars, [StringSplitOptions]::RemoveEmptyEntries)) {
        $conds.Add("__Hay LIKE '%" + (ConvertTo-PwLikeText $w) + "%'")
    }
    if ($Category) { $conds.Add("__Cat = '" + $Category.Replace("'", "''") + "'") }
    $conds -join ' AND '
}

function Set-PwListFilter($List, [string]$Text, [string]$Category) {
    $filter = Get-PwListFilter $Text $Category
    if ($List.View.RowFilter -ne $filter) { $List.View.RowFilter = $filter }
}

function Find-PwListIndex($List, [string]$Name) {
    # 表示中（絞り込み・並べ替え後）の行番号。見つからなければ -1
    if (-not $Name) { return -1 }
    [int]$script:PwFind.Invoke($List.View, @($List.NameProp, $Name))
}
