. (Join-Path $PSScriptRoot 'TestHelper.ps1')

# 一覧のデータ（List.ps1）を、画面を開かずに確かめる
$r = & $Pwm {
    function Info([string]$Name, [hashtable]$Meta) {
        # 実際の SecretInfo.Metadata と同じく、無いキーを引くと例外になる読み取り専用の辞書にする
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        foreach ($k in $Meta.Keys) { $d[$k] = $Meta[$k] }
        [pscustomobject]@{ Name = $Name; Metadata = New-Object 'System.Collections.ObjectModel.ReadOnlyDictionary[string,object]' (, $d) }
    }
    function Titles($List) { @(foreach ($v in $List.View) { $v['__Title'] }) -join ',' }
    function Search($List, [string]$Text, [string]$Cat = '') { Set-PwListFilter $List $Text $Cat; Titles $List }

    $cfg = Get-PwConfig
    $list = New-PwList $cfg
    Import-PwListData $list @(
        (Info 'pwm:b' @{ Title = 'Bank'; Id = 'taro'; Category = '個人'; Note = "1行目`n2行目"; Updated = '2026-02-01 00:00:00' })
        (Info 'pwm:a' @{ Title = 'Amazon'; Email = 'taro@example.com'; Category = '仕事' })
        (Info 'pwm:c' @{ Title = 'カード [本人] 100%'; Id = "o'neil"; Category = "社長's" })
    )
    $o = [ordered]@{}
    $o.Count      = $list.Table.Rows.Count
    $o.Order      = Titles $list
    $o.NoteRow    = $list.ByName['pwm:b'].Row['Note']
    $o.Missing    = $list.ByName['pwm:a'].Row['Id']
    $o.Entry      = Get-PwListEntry $list 'pwm:b'
    $o.EntryNone  = Get-PwListEntry $list 'pwm:zzz'
    $o.And        = Search $list 'taro bank'
    $o.Either     = Search $list 'taro'
    $o.Wide       = Search $list 'ＡＭＡＺＯＮ'
    $o.Kana       = Search $list 'かーど'
    $o.Bracket    = Search $list '[本人]'
    $o.Percent    = Search $list '100%'
    $o.Star       = Search $list '*'
    $o.Quote      = Search $list "o'neil"
    $o.FullSpace  = Search $list "taro　bank"
    $o.NoUpdated  = Search $list '2026-02'
    $o.Cat        = Search $list '' '仕事'
    $o.CatQuote   = Search $list '' "社長's"
    $o.CatAndText = Search $list 'taro' '個人'
    $o.Values     = (Get-PwListValues $list 'Category' @('仕事', '共通')) -join ','
    $o.Extra      = (Get-PwListValues $list 'Category' @()) -join ','
    $o.Sorted     = (@('個人', "社長's") | Sort-Object) -join ','
    $o.SortedAll  = (@('仕事', '個人', "社長's") | Sort-Object) -join ','

    # 1 行単位の更新（絞り込みは表示中の表にそのまま効く。'm' を含むのは Amazon と Docomo だけ）
    Set-PwListFilter $list 'm' ''
    Set-PwListRow $list (Info 'pwm:a' @{ Title = 'Amazon JP'; Category = '仕事' })
    Set-PwListRow $list (Info 'pwm:d' @{ Title = 'Docomo' })
    $o.AfterSet   = Titles $list
    Remove-PwListRow $list 'pwm:b'
    Remove-PwListRow $list 'pwm:nothing'
    $o.AfterDel   = "$(Titles $list) / $($list.Table.Rows.Count) / $($list.ByName.Count)"
    $o.Find       = "$(Find-PwListIndex $list 'pwm:d'),$(Find-PwListIndex $list 'pwm:b'),$(Find-PwListIndex $list '')"

    # 全件の入れ直しでも、絞り込みと並べ替えは引き継ぐ（'e' を含むのは Beta と Zeta）
    Set-PwListFilter $list 'e' ''
    $list.View.Sort = '__Title DESC'
    Import-PwListData $list @((Info 'pwm:x' @{ Title = 'Alpha' }), (Info 'pwm:y' @{ Title = 'Beta' }), (Info 'pwm:z' @{ Title = 'Zeta' }))
    $o.Reimport   = "$(Titles $list) [$($list.View.Sort)]"
    Import-PwListData $list @()
    $o.Empty      = "$($list.Table.Rows.Count)/$($list.ByName.Count)"
    [pscustomobject]$o
}

Write-Host '読み込み'
Check '全件を読み込む'                       ($r.Count -eq 3)
Check '初めはタイトル順'                     ($r.Order -eq 'Amazon,Bank,カード [本人] 100%')
Check '一覧では改行を空白にする'             ($r.NoteRow -eq '1行目 2行目')
Check '無い項目は空欄'                       ($r.Missing -eq '')
Check 'エントリは元の値（改行あり）で返す'   ($r.Entry.Note -eq "1行目`n2行目" -and $r.Entry.Title -eq 'Bank' -and $r.Entry.Name -eq 'pwm:b')
Check '無い名前のエントリは $null'           ($null -eq $r.EntryNone)

Write-Host '検索'
Check '空白区切りは AND 検索'                ($r.And -eq 'Bank')
Check 'タイトル以外の項目も対象'             ($r.Either -eq 'Amazon,Bank')
Check '全角・半角、大文字・小文字を区別しない' ($r.Wide -eq 'Amazon')
Check 'ひらがな・カタカナを区別しない'       ($r.Kana -eq 'カード [本人] 100%')
Check '[ ] を文字として扱う'                 ($r.Bracket -eq 'カード [本人] 100%')
Check '% を文字として扱う'                   ($r.Percent -eq 'カード [本人] 100%')
Check '* を文字として扱う（一致なし）'       ($r.Star -eq '')
Check "' を含む語で検索できる"               ($r.Quote -eq 'カード [本人] 100%')
Check '全角スペースでも区切る'               ($r.FullSpace -eq 'Bank')
Check '更新日時は検索の対象外'               ($r.NoUpdated -eq '')
Check 'カテゴリで絞り込む'                   ($r.Cat -eq 'Amazon')
Check "' を含むカテゴリで絞り込める"         ($r.CatQuote -eq 'カード [本人] 100%')
Check '検索とカテゴリを組み合わせる'         ($r.CatAndText -eq 'Bank')
Check 'カテゴリ候補: 設定の順 → 登録済み（重複なし）' ($r.Values -eq "仕事,共通,$($r.Sorted)")
Check 'カテゴリ候補: 登録済みの値は並べ替える' ($r.Extra -eq $r.SortedAll)

Write-Host '1 行単位の更新'
Check '絞り込み中に更新・追加した行も、条件どおりに出る' ($r.AfterSet -eq 'Amazon JP,Docomo')
Check '削除した行は消える（無い名前は無視）' ($r.AfterDel -eq 'Amazon JP,Docomo / 3 / 3')
Check '表示中の行番号を探せる'               ($r.Find -eq '1,-1,-1')

Write-Host '全件の入れ直し'
Check '絞り込みと並べ替えを引き継ぐ'         ($r.Reimport -eq 'Zeta,Beta [__Title DESC]')
Check '空にできる'                           ($r.Empty -eq '0/0')

Complete-Test
