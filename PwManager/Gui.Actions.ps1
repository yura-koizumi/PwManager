# Gui.Actions.ps1 - 画面の操作（コピー・登録・編集・削除・バックアップ・ロック）
# （PwManager.psm1 から読み込まれる）

function Set-PwUiClipboard($ui, $Value, [bool]$Sensitive, [string]$What) {
    # $Value: パスワードは SecureString（平文の文字列を引数で回さない。Clipboard.ps1 の説明を参照）、ID などは文字列
    if ($Value -is [securestring]) { $secret = $Value; $Sensitive = $true; $seq = Set-PwClipboard -Secret $secret }
    else { $secret = [Net.NetworkCredential]::new('', [string]$Value).SecurePassword; $seq = Set-PwClipboard -Text $Value -Sensitive:$Sensitive }
    $sec = [int]$ui.Cfg.ClipboardClearSeconds
    if ($Sensitive -and $sec -gt 0) {
        $ui.ClipSeq  = $seq
        $ui.ClipHash = Get-PwTextHash $secret
        $ui.ClipExpire = (Get-Date).AddSeconds($sec)
        Set-PwUiStatus $ui "$What をコピーしました（$sec 秒後に消去）"
    } else {
        # 前にコピーしたパスワードは、もうクリップボードに無い。消去までの表示もやめる
        $ui.ClipSeq = $null; $ui.ClipHash = $null; $ui.ClipExpire = $null; $ui.ClipLabel.Text = ''
        Set-PwUiStatus $ui "$What をコピーしました"
    }
}

function Copy-PwUiPassword($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $secret = Invoke-PwVault $ui { Get-PwPassword $e.Name }
    Set-PwUiClipboard $ui $secret $true "「$($e.Title)」のパスワード"
}

function Copy-PwUiPreviousPassword($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $p = Invoke-PwVault $ui { Get-PwPreviousPassword $e.Name }
    if (-not $p) { Set-PwUiStatus $ui "「$($e.Title)」には変更前のパスワードがありません。" -Warn; return }
    Set-PwUiClipboard $ui $p.Secret $true "「$($e.Title)」の変更前のパスワード（$($p.Replaced) まで使用）"
}

function Copy-PwUiField($ui, $Field) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $v = [string]$e.($Field.Name)
    if (-not $v) { Set-PwUiStatus $ui "「$($e.Title)」の$($Field.Label)は空です。" -Warn; return }
    # 秘密にする項目（Sensitive）は、パスワードと同じく SecureString で渡す（引数の値がログに残らないように）
    if ($Field.Sensitive) { $v = [Net.NetworkCredential]::new('', $v).SecurePassword }
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
    # 任意のファイルやコマンドを実行しないよう、http(s) の URL だけ開く。
    # 空白・引用符・制御文字を含むものは、ブラウザーに余計な引数として渡りうるので開かない
    $u = $null
    if ($v -match '[\s"<>\x00-\x1f\x7f]' -or -not [Uri]::TryCreate($v, 'Absolute', [ref]$u) -or $u.Scheme -notin 'http', 'https') {
        Set-PwUiStatus $ui "http:// または https:// で始まる$($Field.Label)だけ開けます（空白や引用符を含むものは開きません）。" -Warn; return
    }
    Start-Process $u.AbsoluteUri
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

function Copy-PwUiEntry($ui) {
    # 選んだエントリの項目（ID・URL など）を入れた新規登録を開く。パスワードは引き継がない
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $saved = Show-PwEditDialog $ui $e -Copy
    if ($saved) { Update-PwUiAfterChange $ui $saved; Set-PwUiStatus $ui '複製して登録しました。' }
}

function Remove-PwUiEntry($ui) {
    $e = Get-PwUiSelected $ui; if (-not $e) { return }
    $yes = Show-PwDialog "「$($e.Title)」を削除しますか？`n`n削除するとバックアップから復元する以外に戻せません。" 'Warn' '削除の確認' -YesNo -Owner $ui.Form
    if (-not $yes -or $ui.Locking) { return }   # 確認中にロックしたら消さない
    Invoke-PwVault $ui { Remove-PwEntry -Name $e.Name -Confirm:$false }
    Update-PwUiAfterChange $ui $e.Name -Removed
    Set-PwUiStatus $ui "「$($e.Title)」を削除しました。"
}

function Invoke-PwUiBackup($ui) {
    # 移行や万一に備えて、手でバックアップを取る（保存先は毎回選ぶ）
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = "バックアップの保存先を選んでください（USB メモリーなど）。`n戻すときは、回復キーが必要です。"
    # ファイル・フォルダーを選ぶ画面は自動ロックで閉じられないので、選んでいる間にロックしていたら何もしない
    if ($fb.ShowDialog($ui.Form) -ne [System.Windows.Forms.DialogResult]::OK -or $ui.Locking) { return }
    $zip = Backup-PwVault -Destination $fb.SelectedPath
    Set-PwUiStatus $ui "バックアップしました: $($zip.FullName)"
}

function Invoke-PwUiImportCsv($ui) {
    # ブラウザー・ほかのツール・Excel の CSV を取り込む（Import-PwCsv と同じ判別）
    $od = New-Object System.Windows.Forms.OpenFileDialog -Property @{
        Title = 'CSV から取り込む'; Filter = 'CSV ファイル (*.csv)|*.csv|すべてのファイル (*.*)|*.*'
    }
    try { if ($od.ShowDialog($ui.Form) -ne [System.Windows.Forms.DialogResult]::OK -or $ui.Locking) { return }; $path = $od.FileName }
    finally { $od.Dispose() }
    $rows = Read-PwCsvRows $path
    if ($rows.Count -eq 0) { Show-PwMessage 'この CSV には取り込める行がありません。' 'Warn'; return }
    $unknown = Get-PwCsvUnknownColumns $rows $ui.Cfg
    if ($unknown.Count -gt 0) {
        $yes = Show-PwDialog ("次の列には、入れる先の項目がありません（値が入っています）:`n  $($unknown -join ', ')`n`n" +
             "この列を取り込まずに続けますか？`n残したいときは「いいえ」を押し、設定ファイルの Fields に項目を追加してから取り込み直してください。") `
            'Warn' 'CSV から取り込む' -YesNo -Owner $ui.Form
        if (-not $yes -or $ui.Locking) { return }
    }
    $ui.Form.UseWaitCursor = $true
    try { $res = Import-PwCsvRows $rows $ui.Cfg $path { param($a) Invoke-PwVault $ui $a } }
    finally {
        $ui.Form.UseWaitCursor = $false
        $ui.LastActivity = Get-Date   # 取り込みに時間がかかっても、終わった直後に自動ロックしないように
        # 途中で止まっても、取り込めた分を一覧に出す。一覧の読み直しに失敗しても、取り込みのエラー（件数を含む）を上書きしない
        if (-not $ui.Locking) { try { Update-PwUiData $ui } catch { } }
    }
    Set-PwUiStatus $ui "$($res.Ok) 件を取り込みました。"
    Show-PwMessage ("$($res.Ok) 件を取り込みました（タイトルかパスワードが空で飛ばした行: $($res.Skip) 件）。`n`n" +
                    "取り込んだ CSV にはパスワードがそのまま残っています。削除して、ごみ箱も空にしてください。")
}

function Invoke-PwUiExportCsv($ui) {
    # CSV に書き出す。形式は保存の画面の「ファイルの種類」で選ぶ
    $sd = New-Object System.Windows.Forms.SaveFileDialog -Property @{
        Title = 'CSV に書き出す'; FileName = "PwManager-$(Get-PwNow 'yyyyMMdd').csv"; DefaultExt = 'csv'
        Filter = 'ブラウザー・ほかのツール向け (*.csv)|*.csv|Excel 向け・パスワードあり (*.csv)|*.csv|Excel 向け・パスワードなし (*.csv)|*.csv'
    }
    try { if ($sd.ShowDialog($ui.Form) -ne [System.Windows.Forms.DialogResult]::OK -or $ui.Locking) { return }; $path = $sd.FileName; $kind = $sd.FilterIndex }
    finally { $sd.Dispose() }
    $withPw = $kind -ne 3
    if ($withPw) {
        $yes = Show-PwDialog "パスワードを暗号化せずに書き出します。`n誰でも開けるファイルになるので、使い終わったらすぐに削除してください。`n`n書き出しますか？" `
            'Warn' 'CSV に書き出す' -YesNo -Owner $ui.Form
        if (-not $yes -or $ui.Locking) { return }
    }
    $format = if ($kind -eq 1) { 'Chrome' } else { 'PwManager' }
    $ui.Form.UseWaitCursor = $true
    try { Invoke-PwVault $ui { Export-PwCsv -Path $path -Format $format -IncludePassword:$withPw -Confirm:$false 3>$null } }
    finally { $ui.Form.UseWaitCursor = $false }
    Set-PwUiStatus $ui "書き出しました: $path"
    if ($withPw) { Show-PwMessage "書き出しました:`n$path`n`n使い終わったら削除して、ごみ箱も空にしてください。" }
}

function Invoke-PwUiConfig($ui) {
    $how = Edit-PwConfig
    $msg = switch ($how) {
        'Explorer' { "メモ帳が見つからないため、設定ファイルの場所をエクスプローラーで開きました。`nテキストエディターで config.json を編集してください。" }
        default    { '設定ファイルを開きました。' }
    }
    Show-PwMessage "$msg`n保存したあと、PwManager を開き直すと反映されます。"
}

function Invoke-PwUiChangePassword($ui) {
    $r = Show-PwChangePasswordDialog $ui
    if (-not $r) { return }
    $ui.UnlockedAt = Get-Date   # 新しいパスワードでロック解除済み
    Set-PwUiStatus $ui 'マスターパスワードを変更しました。次回からは新しいパスワードで開きます。'
}

function Lock-PwUi($ui) {
    # 画面を閉じて、このプロセスを終える（保管庫の鍵やコピーしたパスワードをメモリーに残さないため）。
    # 起動し直しとクリップボードの消去は Show-PwManager の最後で行う
    $ui.Locking = $true
    $ui.Form.Close()
}

function Invoke-PwUiAutoLock($ui) {
    # 無操作が続いたらロックする。編集やマスターパスワードの再入力などの子画面が開いていれば、先に閉じる
    # （再入力の画面を出したまま離席しても、後ろの一覧を出し続けないように）
    if (-not $ui.Locking) {
        $lockMin = [double]$ui.Cfg.AutoLockMinutes
        if ($lockMin -le 0 -or ((Get-Date) - $ui.LastActivity).TotalMinutes -lt $lockMin) { return }
        $ui.Locking = $true   # これ以降、子画面を閉じたことによるエラー（キャンセルなど）は表示しない
    }
    $others = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_ -ne $ui.Form })
    if ($others.Count -gt 0) {
        # 子画面のモーダル処理が終わってから閉じる（次のタイマーで再判定）
        foreach ($f in $others) { $f.Close() }
        return
    }
    Lock-PwUi $ui
}

