# Csv.ps1 - CSV の取り込み・書き出し（Excel・ブラウザー・ほかのパスワード管理ツールとの移行）
# （PwManager.psm1 から読み込まれる）

# Excel で開いたとき数式として実行されないよう、= + - @ タブ CR で始まる値の先頭に ' を付ける。
# パスワードは値を変えないため対象外。Import-PwCsv は付けた ' を 1 つ取り除く。
# もともと ' で始まる値（'=x など）も元どおりに戻るよう、先頭の ' を飛ばして判定し、同じく ' を付ける
$script:CsvFormulaPattern = "^'*[=+\-@`t`r]"

function Protect-PwCsvValue([string]$Value) {
    if ($Value -match $script:CsvFormulaPattern) { "'" + $Value } else { $Value }
}

function Unprotect-PwCsvValue([string]$Value) {
    if ($Value.Length -gt 1 -and $Value[0] -eq "'" -and $Value.Substring(1) -match $script:CsvFormulaPattern) { $Value.Substring(1) } else { $Value }
}

# 取り込むときの列名（大文字小文字は区別しない）。ブラウザーやほかのパスワード管理ツールの CSV もそのまま読めるようにする
#   Chrome / Edge : name, url, username, password, note
#   Firefox       : url, username, password, httpRealm, formActionOrigin, guid, timeCreated, timeLastUsed, timePasswordChanged
#   Bitwarden     : folder, favorite, type, name, notes, fields, reprompt, login_uri, login_username, login_password, login_totp
#   1Password     : Title, Url, Username, Password, OTPAuth, Favorite, Archived, Tags, Notes
#   KeePass       : Account, Login Name, Password, Web Site, Comments
$script:CsvTitleColumns    = 'Title', 'タイトル', 'サービス', 'Service', 'サービス名', 'name', 'Account'
$script:CsvPasswordColumns = 'Password', 'パスワード', 'PW', 'login_password'
$script:CsvFieldAliases    = @{    # 項目の Name → その項目に入れる列名（その項目が設定にあるときだけ使う）
    Id   = 'username', 'login_username', 'Login Name', 'User Name', 'UserName'
    Url  = 'login_uri', 'Web Site', 'Website'
    Note = 'notes', 'Comments'
}
# 読まなくてよい列（日時は取り込むときに付け直す。ほかはツールごとの管理用の値）
$script:CsvIgnoredColumns  = 'Updated', 'Created', '更新日時', '作成日時', 'httpRealm', 'formActionOrigin', 'guid',
                             'timeCreated', 'timeLastUsed', 'timePasswordChanged', 'folder', 'favorite', 'type', 'reprompt', 'Archived'

function Get-PwCsvFieldColumns($Field) {
    # その項目に入れる列名（Name・Label と、ほかのツールでの呼び名）
    @($Field.Name, $Field.Label) + @($script:CsvFieldAliases[$Field.Name])
}

function Import-PwCsv {
    <#
    .SYNOPSIS
      CSV を取り込む（Excel・ブラウザー・ほかのパスワード管理ツールから）。
    .DESCRIPTION
      列名から自動で判別する。Chrome・Edge・Firefox・Bitwarden・1Password・KeePass が書き出す CSV は、そのまま取り込める。
      自分で作るときの列: Title（タイトル）・Password（パスワード）と、設定 Fields の Name または Label（例: Id・Url・Note）。
      タイトルの列が無い CSV（Firefox）は、URL のドメイン名をタイトルにする。タイトルかパスワードが空の行は取り込まない。
      どれにも当てはまらない列（2 段階認証の鍵 login_totp・OTPAuth など）に値が入っていると、データを取りこぼさないよう止まる
      （-IgnoreUnknownColumns でその列を無視して続ける）。列があっても、値が空なら止まらない。
      文字コードは自動で判別する（UTF-8 と、Excel の「CSV (コンマ区切り)」の Shift-JIS）。
      PwManager の画面を閉じてから実行する。取り込んだら、CSV と元のファイルは削除し、ごみ箱も空にすること。
    .PARAMETER Path
      CSV ファイル。
    .PARAMETER Encoding
      文字コード。既定の Auto で自動判別。うまく読めないときだけ UTF8 か Default（Shift-JIS）を指定する。
    .PARAMETER IgnoreUnknownColumns
      取り込み先の項目が無い列を無視して続ける。
    .EXAMPLE
      Import-PwCsv -Path 'C:\work\Chrome パスワード.csv'
    .EXAMPLE
      Import-PwCsv -Path 'C:\work\passwords.csv' -IgnoreUnknownColumns
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Auto', 'UTF8', 'Default')][string]$Encoding = 'Auto',
        [switch]$IgnoreUnknownColumns
    )
    Assert-PwGuiClosed
    $cfg = Get-PwConfig
    $rows = Read-PwCsvRows $Path $Encoding
    $unknown = Get-PwCsvUnknownColumns $rows $cfg
    if ($unknown.Count -gt 0 -and -not $IgnoreUnknownColumns) {
        throw ("取り込み先の項目が無い列があります: {0}`n" +
               "設定の Fields に項目を追加してから取り込むか（README「項目（Fields）を追加・変更する」）、" +
               "その列を取り込まなくてよければ -IgnoreUnknownColumns を付けて実行してください。") -f ($unknown -join ', ')
    }
    if ($rows.Count -eq 0) { Write-Warning 'この CSV には取り込める行がありません（空か、見出しの行だけです）。'; return }
    $r = Import-PwCsvRows $rows $cfg $Path
    Write-Host "$($r.Ok) 件を取り込みました。（タイトルかパスワードが空でスキップ: $($r.Skip) 件）" -ForegroundColor Green
    Write-Warning '取り込みが済んだら、元の CSV ファイルは削除し、ごみ箱も空にしてください（パスワードが平文で残っています）。'
}

function Read-PwCsvRows([string]$Path, [string]$Encoding = 'Auto') {
    # CSV を読む。Auto は、BOM があるか UTF-8 として正しく読めれば UTF-8、そうでなければ Excel の「CSV (コンマ区切り)」（Shift-JIS）
    # .NET のメソッドは PowerShell の今いるフォルダーを知らないので、相対パスを先に解決する
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($Encoding -eq 'Auto') {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $Encoding = 'UTF8'
        if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
            try { [void](New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { $Encoding = 'Default' }
        }
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    $rows = @(Import-Csv -LiteralPath $Path -Encoding $Encoding)
    # パスワードの列は、読んだらすぐ SecureString にする（このあと行をコマンドに渡しても、パスワードがログに残らないように。
    # Clipboard.ps1 の説明を参照）。.NET のメソッドで変換するので、変換そのものもログに残らない
    foreach ($r in $rows) {
        foreach ($p in $r.PSObject.Properties) {
            if ($script:CsvPasswordColumns -contains $p.Name) {
                $v = [string]$p.Value
                $p.Value = if ($v) { [Net.NetworkCredential]::new('', $v).SecurePassword } else { $null }
            }
        }
    }
    $v = $null
    , $rows
}

function Write-PwCsvFile([string]$Path, [string[]]$Columns, $Rows, [bool]$Bom) {
    # CSV を書く。値はすべて "" で囲む（Export-Csv と同じ形）。SecureString の値は、書く直前に平文に戻す。
    # Export-Csv・ConvertTo-Csv は、渡した行（パスワードを含む）が引数としてログに残りうるので使わない
    $quote = { param([string]$s) '"' + $s.Replace('"', '""') + '"' }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append((@(foreach ($c in $Columns) { & $quote $c }) -join ',')).Append("`r`n")
    foreach ($row in @($Rows)) {
        $first = $true
        foreach ($c in $Columns) {
            if (-not $first) { [void]$sb.Append(',') }
            $first = $false
            $v = $row[$c]
            if ($v -is [securestring]) {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($v)
                try { [void]$sb.Append('"').Append([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Replace('"', '""')).Append('"') }
                finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            } else {
                [void]$sb.Append((& $quote ([string]$v)))
            }
        }
        [void]$sb.Append("`r`n")
    }
    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding $Bom))
    [void]$sb.Clear()
}

function Get-PwCsvUnknownColumns($Rows, $Cfg) {
    # 入れる先の無い列のうち、値が入っているもの。
    # 値が 1 つも入っていなければ失うものは無いので数えない
    # （Bitwarden・1Password は、使っていなくても login_totp・fields・OTPAuth・Tags の列を必ず書き出す）
    $known = @($script:CsvTitleColumns) + @($script:CsvPasswordColumns) + @($script:CsvIgnoredColumns) +
             @(foreach ($f in @($Cfg.Fields)) { Get-PwCsvFieldColumns $f })
    , @(if (@($Rows).Count -gt 0) {
        $Rows[0].PSObject.Properties.Name | Where-Object { $known -notcontains $_ } |
            Where-Object { $col = $_; @($Rows | Where-Object { $_.$col }).Count -gt 0 }
    })
}

function Import-PwCsvRows($Rows, $Cfg, [string]$Path, [scriptblock]$Wrap = { param($a) & $a }) {
    # 読んだ行を登録する（入れる先の無い列は無視する）。@{ Ok = 取り込んだ件数; Skip = 飛ばした件数 } を返す。
    # -Wrap: 1 件ずつの保存を包む（画面では、途中で保管庫のロックが切れても、その 1 件だけをやり直すように）
    $cfg = $Cfg
    $rows = @($Rows)
    $pick = {
        param($Row, [string[]]$Keys)
        foreach ($k in $Keys) { $p = $Row.PSObject.Properties[$k]; if ($p -and $p.Value) { return [string]$p.Value } }
        ''
    }
    $urlField = @($cfg.Fields | Where-Object { $_.Name -eq 'Url' })[0]
    $urlColumns = @('url') + @(if ($urlField) { Get-PwCsvFieldColumns $urlField })
    # Excel 用に付けた ' を外すのは、PwManager の既定の形で書き出した CSV（Updated の列がある）だけ。
    # ほかのツールや Chrome 形式の CSV は値をそのまま書いているので、もともと ' で始まる値を削らない
    $unprotect = $rows.Count -gt 0 -and $null -ne $rows[0].PSObject.Properties['Updated']
    $clean = { param([string]$v) if ($unprotect) { Unprotect-PwCsvValue $v } else { $v } }
    $ok = 0; $skip = 0
    try {
    foreach ($r in $rows) {
        $title = & $clean (& $pick $r $script:CsvTitleColumns)
        $pw = $null   # Read-PwCsvRows で SecureString にしてある
        foreach ($k in $script:CsvPasswordColumns) {
            $p = $r.PSObject.Properties[$k]
            if ($p -and $p.Value -is [securestring] -and $p.Value.Length -gt 0) { $pw = $p.Value; break }
        }
        if (-not $title) {
            # タイトルの列が無い（Firefox）ときは、URL のドメイン名にする
            $url = & $pick $r $urlColumns
            $u = $null
            if ($url -and [Uri]::TryCreate($url, 'Absolute', [ref]$u) -and $u.Host) { $title = $u.Host -replace '^www\.', '' }
        }
        if (-not $title -or -not $pw) { $skip++; continue }
        $fields = @{}
        foreach ($f in @($cfg.Fields)) { $fields[$f.Name] = & $clean (& $pick $r (Get-PwCsvFieldColumns $f)) }
        & $Wrap { Save-PwEntry -Title $title -Fields $fields -Password $pw | Out-Null }
        $ok++
    }
    } catch {
        # 途中で止まっても、それまでに登録した件数を知らせる（同じ CSV を取り込み直すと、その分が重複するため）
        throw "$ok 件を取り込んだところで止まりました（残りの行は取り込んでいません。同じ CSV を取り込み直すと、取り込んだ $ok 件は重複します）。`n$($_.Exception.Message)"
    } finally { Write-PwAudit 'IMPORT' "$Path ($ok 件)" }
    @{ Ok = $ok; Skip = $skip }
}

function Export-PwCsv {
    <#
    .SYNOPSIS
      一覧を CSV に書き出す（ほかのツールやブラウザーへの移行用）。
    .DESCRIPTION
      既定（-Format PwManager）は、Title・Password・設定の各項目・Updated の列。Excel で開いても数式として実行されないよう、
      = + - @ で始まる値には先頭に ' を付ける（Import-PwCsv で元に戻る）。-IncludePassword を付けるとパスワードを平文で含める。
      -Format Chrome は、Chrome・Edge・Firefox・Bitwarden・1Password などが取り込める形（name,url,username,password,note）で、
      パスワードを必ず含める。値はそのまま書く（取り込む側に ' が残らないように）ので、Excel では開かないこと。
      パスワードを含めるときは確認してから書き出す。使い終わったら CSV は削除し、ごみ箱も空にすること。
    .PARAMETER Path
      書き出す CSV ファイル。
    .PARAMETER Format
      PwManager（既定）または Chrome。
    .PARAMETER IncludePassword
      パスワードを平文で含める（-Format Chrome では常に含める）。
    .EXAMPLE
      Export-PwCsv -Path 'out.csv' -IncludePassword
    .EXAMPLE
      Export-PwCsv -Path 'chrome.csv' -Format Chrome    # ブラウザーやほかのツールに取り込む
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('PwManager', 'Chrome')][string]$Format = 'PwManager',
        [switch]$IncludePassword
    )
    $cfg = Get-PwConfig
    $chrome = $Format -eq 'Chrome'
    if ($chrome) { $IncludePassword = $true }
    if ($IncludePassword -and -not $PSCmdlet.ShouldProcess($Path, 'パスワードを平文で書き出す')) { return }
    $has = @{}
    foreach ($f in @($cfg.Fields)) { $has[$f.Name] = $true }
    # パスワードは SecureString のまま行に入れ、Write-PwCsvFile が書く直前に平文に戻す
    $columns = if ($chrome) { 'name', 'url', 'username', 'password', 'note' }
               else { @('Title') + @(if ($IncludePassword) { 'Password' }) + @($cfg.Fields | ForEach-Object Name) + @('Updated') }
    $rows = foreach ($e in @(Get-PwEntry -All)) {
        if ($chrome) {
            @{
                name     = $e.Title
                url      = $(if ($has['Url']) { $e.Url } else { '' })
                username = $(if ($has['Id']) { $e.Id } else { '' })
                password = Get-PwPassword $e.Name
                note     = $(if ($has['Note']) { $e.Note } else { '' })
            }
        } else {
            $h = @{ Title = Protect-PwCsvValue $e.Title; Updated = $e.Updated }
            if ($IncludePassword) { $h['Password'] = Get-PwPassword $e.Name }
            foreach ($f in @($cfg.Fields)) { $h[$f.Name] = Protect-PwCsvValue $e.($f.Name) }
            $h
        }
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    # 0 件でも列名の行は書く（空のファイルは、取り込む側で形式の誤りとして断られるため）。
    # Chrome 形式は BOM なし（ブラウザーは先頭の BOM を列名の一部として読むことがある）、既定の形は Excel で文字化けしないよう BOM 付き
    Write-PwCsvFile $full $columns @($rows) (-not $chrome)
    Write-PwAudit $(if ($IncludePassword) { 'EXPORT+PW' } else { 'EXPORT' }) $Path
    if ($IncludePassword) { Write-Warning '平文のパスワードを含むファイルです。用が済んだらすぐに削除し、ごみ箱も空にしてください。' }
}
