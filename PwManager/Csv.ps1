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
      Excel の「CSV (コンマ区切り)」は -Encoding Default、それ以外（ブラウザーや「CSV UTF-8」）は既定の UTF8。
      PwManager の画面を閉じてから実行する。取り込んだら、CSV と元のファイルは削除し、ごみ箱も空にすること。
    .PARAMETER Path
      CSV ファイル。
    .PARAMETER Encoding
      文字コード（UTF8 または Default）。
    .PARAMETER IgnoreUnknownColumns
      取り込み先の項目が無い列を無視して続ける。
    .EXAMPLE
      Import-PwCsv -Path 'C:\work\Chrome パスワード.csv'
    .EXAMPLE
      Import-PwCsv -Path 'C:\work\passwords.csv' -Encoding Default -IgnoreUnknownColumns
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('UTF8', 'Default')][string]$Encoding = 'UTF8',
        [switch]$IgnoreUnknownColumns
    )
    Assert-PwGuiClosed
    $cfg = Get-PwConfig
    $rows = @(Import-Csv -LiteralPath $Path -Encoding $Encoding)
    $known = @($script:CsvTitleColumns) + @($script:CsvPasswordColumns) + @($script:CsvIgnoredColumns) +
             @(foreach ($f in @($cfg.Fields)) { Get-PwCsvFieldColumns $f })
    # 入れる先の無い列でも、値が 1 つも入っていなければ失うものは無いので止めない
    # （Bitwarden・1Password は、使っていなくても login_totp・fields・OTPAuth・Tags の列を必ず書き出す）
    $unknown = @(if ($rows.Count -gt 0) {
        $rows[0].PSObject.Properties.Name | Where-Object { $known -notcontains $_ } |
            Where-Object { $col = $_; @($rows | Where-Object { $_.$col }).Count -gt 0 }
    })
    if ($unknown.Count -gt 0 -and -not $IgnoreUnknownColumns) {
        throw ("取り込み先の項目が無い列があります: {0}`n" +
               "設定の Fields に項目を追加してから取り込むか（README「項目（Fields）を追加・変更する」）、" +
               "その列を取り込まなくてよければ -IgnoreUnknownColumns を付けて実行してください。") -f ($unknown -join ', ')
    }
    $pick = {
        param($Row, [string[]]$Keys)
        foreach ($k in $Keys) { $p = $Row.PSObject.Properties[$k]; if ($p -and $p.Value) { return [string]$p.Value } }
        ''
    }
    $urlField = @($cfg.Fields | Where-Object { $_.Name -eq 'Url' })[0]
    $urlColumns = @('url') + @(if ($urlField) { Get-PwCsvFieldColumns $urlField })
    $ok = 0; $skip = 0
    foreach ($r in $rows) {
        $title = Unprotect-PwCsvValue (& $pick $r $script:CsvTitleColumns)
        $pw    = & $pick $r $script:CsvPasswordColumns
        if (-not $title) {
            # タイトルの列が無い（Firefox）ときは、URL のドメイン名にする
            $url = & $pick $r $urlColumns
            $u = $null
            if ($url -and [Uri]::TryCreate($url, 'Absolute', [ref]$u) -and $u.Host) { $title = $u.Host -replace '^www\.', '' }
        }
        if (-not $title -or -not $pw) { $skip++; continue }
        $fields = @{}
        foreach ($f in @($cfg.Fields)) { $fields[$f.Name] = Unprotect-PwCsvValue (& $pick $r (Get-PwCsvFieldColumns $f)) }
        Save-PwEntry -Title $title -Fields $fields -Password (ConvertTo-SecureString $pw -AsPlainText -Force) | Out-Null
        $ok++
    }
    Write-PwAudit 'IMPORT' "$Path ($ok 件)"
    Write-Host "$ok 件を取り込みました。（タイトルかパスワードが空でスキップ: $skip 件）" -ForegroundColor Green
    Write-Warning '取り込みが済んだら、元の CSV ファイルは削除し、ごみ箱も空にしてください（パスワードが平文で残っています）。'
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
    $rows = foreach ($e in @(Get-PwEntry -All)) {
        if ($chrome) {
            [pscustomobject][ordered]@{
                name     = $e.Title
                url      = $(if ($has['Url']) { $e.Url } else { '' })
                username = $(if ($has['Id']) { $e.Id } else { '' })
                password = Get-PwPassword $e.Name
                note     = $(if ($has['Note']) { $e.Note } else { '' })
            }
        } else {
            $h = [ordered]@{ Title = Protect-PwCsvValue $e.Title }
            if ($IncludePassword) { $h['Password'] = Get-PwPassword $e.Name }
            foreach ($f in @($cfg.Fields)) { $h[$f.Name] = Protect-PwCsvValue $e.($f.Name) }
            $h['Updated'] = $e.Updated
            [pscustomobject]$h
        }
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $rows) {
        # 0 件でも、列名の行だけは書く（空のファイルは、取り込む側で形式の誤りとして断られるため）
        $header = if ($chrome) { 'name', 'url', 'username', 'password', 'note' }
                  else { @('Title') + @(if ($IncludePassword) { 'Password' }) + @($cfg.Fields | ForEach-Object Name) + @('Updated') }
        [IO.File]::WriteAllLines($full, [string[]]@(($header | ForEach-Object { '"' + $_ + '"' }) -join ','), (New-Object Text.UTF8Encoding (-not $chrome)))
    } elseif ($chrome) {
        # ブラウザーは先頭の BOM を列名の一部として読むことがあるので、BOM なしの UTF-8 で書く
        $lines = [string[]]@(@($rows) | ConvertTo-Csv -NoTypeInformation)
        [IO.File]::WriteAllLines($full, $lines, (New-Object Text.UTF8Encoding $false))
    } else {
        @($rows) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8   # Excel で文字化けしないよう BOM 付き
    }
    Write-PwAudit $(if ($IncludePassword) { 'EXPORT+PW' } else { 'EXPORT' }) $Path
    if ($IncludePassword) { Write-Warning '平文のパスワードを含むファイルです。用が済んだらすぐに削除し、ごみ箱も空にしてください。' }
}
