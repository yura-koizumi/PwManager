# Cli.ps1 - PowerShell から登録・編集・削除するコマンド（画面と同じ処理を使う）
# （PwManager.psm1 から読み込まれる）
#
# パスワードは引数に平文で渡さない（コマンド履歴に残るため）。-Generate で生成するか、入力を求める。
# 保管庫に書き込むコマンドは、PwManager の画面が別に開いている間は実行しない
# （2 つのプロセスが同じ保管庫ファイルに書くと、片方の変更が失われるおそれがあるため）。

function Resolve-PwEntry([string]$Query) {
    # 検索語からエントリを 1 件に決める。タイトルが完全に一致すればそれ、候補が複数なら選んでもらう
    $hits = @(Get-PwEntry -Filter $Query -All)
    $exact = @($hits | Where-Object { $_.Title -eq $Query })
    if ($exact.Count -eq 1) { $hits = $exact }
    if ($hits.Count -eq 0) { throw "「$Query」に一致するエントリはありません。" }
    if ($hits.Count -eq 1) { return $hits[0] }
    $hits | Out-GridView -Title "「$Query」に一致するエントリが $($hits.Count) 件あります。対象を選んで [OK] を押してください" -OutputMode Single
}

function Get-PwEntryByName([string]$Name) {
    $info = @(Get-PwSecretInfo $Name)
    if ($info.Count -eq 0) { throw "エントリが見つかりません: $Name" }
    ConvertTo-PwEntry $info[0].Name $info[0].Metadata (Get-PwEntryKeys (Get-PwConfig))
}

function ConvertTo-PwFieldValues([hashtable]$Fields) {
    # -Fields のキーは項目の Name でも Label（画面の表示名）でもよい。保存用に Name へそろえる
    $cfg = Get-PwConfig
    $out = @{}
    foreach ($k in @($Fields.Keys)) {
        $def = @($cfg.Fields | Where-Object { $_.Name -eq $k -or $_.Label -eq $k }) | Select-Object -First 1
        if (-not $def) { throw "項目 '$k' は設定にありません。使える項目: $(($cfg.Fields | ForEach-Object Name) -join ', ')" }
        $out[$def.Name] = $Fields[$k]
    }
    $out
}

function Read-PwEntryPassword {
    # パスワードを 2 回入力してもらう（一致して空でないまで繰り返す）
    while ($true) {
        $p1 = Read-Host 'パスワード' -AsSecureString
        $p2 = Read-Host '確認のためもう一度' -AsSecureString
        if ($p1.Length -eq 0) { Write-Warning 'パスワードを入力してください。'; continue }
        if (-not (Test-PwSecureStringEqual $p1 $p2)) { Write-Warning '一致しません。もう一度入力してください。'; continue }
        return $p1
    }
}

function Get-PwNewSecret([securestring]$Password, [switch]$Generate, [switch]$Prompt) {
    # -Password / -Generate / 入力 のどれかでパスワードを決める（どれも無ければ $null）
    if ($Generate -and $Password) { throw '-Password と -Generate は同時に指定できません。' }
    if ($Generate) {
        $s = New-Object System.Security.SecureString
        foreach ($c in (New-PwPassword).ToCharArray()) { $s.AppendChar($c) }
        $s.MakeReadOnly()
        return $s
    }
    if ($Password) { return $Password }
    if ($Prompt) { return Read-PwEntryPassword }
    $null
}

function New-PwEntry {
    <#
    .SYNOPSIS
      エントリを登録する。
    .DESCRIPTION
      パスワードは -Generate で生成するか、入力を求める（引数に平文で書くと、コマンドの履歴に残るため）。
      PwManager の画面を閉じてから実行する。
    .PARAMETER Title
      タイトル（サービス名など）。
    .PARAMETER Fields
      項目の値。キーは項目の Name でも Label でもよい（例: @{ ID = 'taro'; URL = 'https://…' }）。
    .PARAMETER Password
      パスワード（SecureString）。省略すると入力を求める。
    .PARAMETER Generate
      パスワードを生成する（長さなどは設定の PasswordGenerator）。
    .EXAMPLE
      New-PwEntry 'Amazon' -Fields @{ ID = 'taro'; URL = 'https://www.amazon.co.jp' } -Generate
      # パスワードを生成して登録（Copy-PwField Amazon でコピーできる）
    .EXAMPLE
      New-PwEntry '社内ポータル' -Fields @{ Id = 'u001' }
      # パスワードは入力を求める
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Title,
        [hashtable]$Fields = @{},
        [securestring]$Password,
        [switch]$Generate
    )
    Assert-PwGuiClosed
    if (-not $Title.Trim()) { throw 'タイトルを入力してください。' }
    $values = ConvertTo-PwFieldValues $Fields
    $secret = Get-PwNewSecret -Password $Password -Generate:$Generate -Prompt
    if (-not $PSCmdlet.ShouldProcess($Title, '登録')) { return }
    $name = Save-PwEntry -Title $Title -Fields $values -Password $secret
    if ($Generate) { Write-Host "パスワードを生成して登録しました。Copy-PwField '$($Title.Trim())' でコピーできます。" -ForegroundColor Green }
    Get-PwEntryByName $name
}

function Set-PwEntry {
    <#
    .SYNOPSIS
      エントリを編集する（指定した項目だけを変える）。
    .DESCRIPTION
      指定しなかった項目とパスワードはそのまま。
      PwManager の画面を閉じてから実行する。
    .PARAMETER Query
      対象の検索語（Get-PwEntry と同じ）。タイトルが完全に一致すればそれ、候補が複数なら選ぶ画面が出る。
    .PARAMETER Name
      対象の ID（pwm:…）。Get-PwEntry の結果をパイプで渡すと使われる。
    .PARAMETER Title
      新しいタイトル。
    .PARAMETER Fields
      変える項目の値。キーは項目の Name でも Label でもよい。空文字を渡すと、その項目を空にする。
    .PARAMETER Password
      新しいパスワード（SecureString）。
    .PARAMETER Generate
      パスワードを生成し直す。
    .PARAMETER PromptPassword
      新しいパスワードの入力を求める。
    .EXAMPLE
      Set-PwEntry 'Amazon' -Fields @{ URL = 'https://www.amazon.com' }
    .EXAMPLE
      Set-PwEntry 'Amazon' -Generate          # パスワードを生成し直す
      Set-PwEntry 'Amazon' -PromptPassword    # 新しいパスワードを入力する
    .EXAMPLE
      Get-PwEntry '旧システム' | Set-PwEntry -Title '新システム'
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Query')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Query')][string]$Query,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'Name')][string]$Name,
        [string]$Title,
        [hashtable]$Fields = @{},
        [securestring]$Password,
        [switch]$Generate,
        [switch]$PromptPassword
    )
    begin { Assert-PwGuiClosed }
    process {
        $entry = if ($PSCmdlet.ParameterSetName -eq 'Name') { Get-PwEntryByName $Name } else { Resolve-PwEntry $Query }
        if (-not $entry) { return }
        $newTitle = if ($PSBoundParameters.ContainsKey('Title')) { $Title } else { $entry.Title }
        if (-not $newTitle.Trim()) { throw 'タイトルを空にはできません。' }
        $values = ConvertTo-PwFieldValues $Fields
        $secret = Get-PwNewSecret -Password $Password -Generate:$Generate -Prompt:$PromptPassword
        if (-not $PSBoundParameters.ContainsKey('Title') -and $values.Count -eq 0 -and -not $secret) {
            Write-Warning '変更する内容がありません（-Title / -Fields / -Generate / -PromptPassword / -Password のどれかを指定します）。'
            return
        }
        if (-not $PSCmdlet.ShouldProcess($entry.Title, '更新')) { return }
        $name = Save-PwEntry -Name $entry.Name -Title $newTitle -Fields $values -Password $secret
        if ($Generate) { Write-Host "パスワードを生成し直しました。Copy-PwField '$($newTitle.Trim())' でコピーできます。" -ForegroundColor Green }
        Get-PwEntryByName $name
    }
}
