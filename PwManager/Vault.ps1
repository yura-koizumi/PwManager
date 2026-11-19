# Vault.ps1 - 保管庫の操作（SecretManagement / SecretStore）
# （PwManager.psm1 から読み込まれる）

function Test-PwLockedError($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e) {
        if ($e.GetType().Name -match 'PasswordRequired' -or
            $e.Message -match 'Unlock-SecretStore|password is required|NonInteractive') { return $true }
        $e = $e.InnerException
    }
    $false
}

function ConvertFrom-PwSecureString([securestring]$Secure) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Register-PwVaultIfMissing($Cfg) {
    if (-not (Get-SecretVault -Name $Cfg.VaultName -ErrorAction SilentlyContinue)) {
        $hasDefault = @(Get-SecretVault -ErrorAction SilentlyContinue | Where-Object { $_.IsDefault }).Count -gt 0
        Register-SecretVault -Name $Cfg.VaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault:(-not $hasDefault)
        Write-Host "保管庫 '$($Cfg.VaultName)' を登録しました。"
    }
}

function Unlock-PwVault([securestring]$StorePassword) {
    # 保管庫キーから作った SecretStore のパスワードで開く（マスターパスワードからは Invoke-PwUnlock を使う）
    $cfg = Get-PwConfig
    Unlock-SecretStore -Password $StorePassword -PasswordTimeout ([int]$cfg.UnlockTimeoutSeconds)
}

function Use-PwVault([scriptblock]$Action) {
    # コマンドから使うとき、保管庫がロックされていればマスターパスワードを尋ねて開き、1 回だけやり直す。
    # 画面の表示中は、画面側（Invoke-PwVault）が解除の画面を出すので、ここでは尋ねない
    try { & $Action }
    catch {
        if ($script:PinnedConfig -or -not (Test-PwLockedError $_)) { throw }
        for ($i = 1; ; $i++) {
            $pw = Read-Host 'マスターパスワード' -AsSecureString
            try { $before = Invoke-PwUnlock $pw; break }
            catch { if ($i -ge 3) { throw }; Write-Warning $_.Exception.Message }
        }
        if ($before.Count -gt 0) {
            Write-Warning ("前回正しく開いてから、マスターパスワードの入力に {0} 回失敗しています（最後: {1}）。" -f $before.Count, $before.Last)
        }
        & $Action
    }
}

#region ロック解除の失敗（総当たり対策）
# 画面からのロック解除に続けて失敗すると、次に試せるまでの待ち時間を延ばす（ふだんの打ち間違いでは待たない）。
# 回数と最後の日時を %APPDATA%\PwManager\unlock.json に残し、次に正しく開いたときに本人へ知らせる。
# ※ 保管庫ファイルを直接狙う攻撃（オフライン攻撃）は、保管庫キーを Windows ユーザーに結び付けて防ぐ（Key.ps1）。

$script:UnlockFailPath  = Join-Path $script:DataDir 'unlock.json'
$script:UnlockFreeTries = 4      # この回数までは待たない
$script:UnlockMaxWait   = 300    # 待ち時間の上限（秒）

function Get-PwUnlockFailures {
    # @{ Count = 連続して失敗した回数; Last = 最後に失敗した日時（無ければ $null） }
    $r = @{ Count = 0; Last = $null }
    if (Test-Path -LiteralPath $script:UnlockFailPath) {
        try {
            $j = Read-PwJson $script:UnlockFailPath
            $r.Count = [int]$j.Count
            $r.Last = [datetime]::ParseExact([string]$j.Last, $script:DateFormat, [Globalization.CultureInfo]::InvariantCulture)
        } catch { }
    }
    $r
}

function Get-PwUnlockWait([int]$Count) {
    # 連続 $Count 回失敗したあと、次に試せるまでの秒数（5 回目から 5, 10, 20, … 秒、上限 5 分）
    if ($Count -le $script:UnlockFreeTries) { return 0 }
    [int][Math]::Min($script:UnlockMaxWait, 5 * [Math]::Pow(2, $Count - $script:UnlockFreeTries - 1))
}

function Get-PwUnlockRemaining {
    # 次に試せるまでの残り秒数（0 ならすぐ試せる）
    $f = Get-PwUnlockFailures
    if (-not $f.Last) { return 0 }
    $left = (Get-PwUnlockWait $f.Count) - ((Get-Date) - $f.Last).TotalSeconds
    [int][Math]::Max(0, [Math]::Ceiling($left))
}

function Invoke-PwUnlock([securestring]$Password) {
    <# 待ち時間を守ってロック解除する。失敗すれば回数を増やして例外を投げ直す。
       成功すれば回数を 0 に戻し、それまでの失敗（@{ Count; Last }）を返す。 #>
    $left = Get-PwUnlockRemaining
    if ($left -gt 0) { throw "パスワードの入力に続けて失敗したため、あと $left 秒待ってから入力してください。" }
    $before = Get-PwUnlockFailures
    try {
        $vk = Get-PwVaultKey $Password
    } catch {
        if ($_.Exception -is [Security.Authentication.InvalidCredentialException]) {   # パスワード違いだけを数える
            $n = $before.Count + 1
            Initialize-PwDataDir
            @{ Count = $n; Last = (Get-Date -Format $script:DateFormat) } | ConvertTo-Json | Set-Content -LiteralPath $script:UnlockFailPath -Encoding UTF8
            Write-PwAudit 'UNLOCK-FAIL' "連続 $n 回目"
        }
        throw
    }
    try { Unlock-PwVault (ConvertTo-PwStorePassword $vk) } finally { Clear-PwBytes $vk }
    if ($before.Count -gt 0) {
        Remove-Item -LiteralPath $script:UnlockFailPath -Force -ErrorAction SilentlyContinue
        Write-PwAudit 'UNLOCK' "それまでに $($before.Count) 回失敗"
    }
    $before
}

#endregion

function Get-PwSecretInfo([string]$Name) {
    <# 保管庫のエントリ情報（SecretInfo）を並べ替えずに返す。-Name を指定するとその 1 件だけ。画面からも使う。 #>
    $cfg = Get-PwConfig
    $pattern = if ($Name) { $Name } else { "$($script:SecretPrefix)*" }
    foreach ($info in @(Use-PwVault { Get-SecretInfo -Vault $cfg.VaultName -Name $pattern })) {
        if (-not $Name -or $info.Name -eq $Name) { $info }
    }
}

function Get-PwEntryKeys($Cfg) {
    # エントリの項目名（Name 以外）
    [string[]](@('Title') + @(foreach ($f in $Cfg.Fields) { $f.Name }) + @('Created', 'Updated'))
}

function ConvertTo-PwEntry([string]$Name, $Meta, [string[]]$Keys) {
    # Metadata は読み取り専用の辞書で、無いキーを引くと例外になるため ContainsKey で確かめる
    $h = [ordered]@{ Name = $Name }
    foreach ($k in $Keys) { $h[$k] = if ($Meta -and $Meta.ContainsKey($k)) { [string]$Meta[$k] } else { '' } }
    [pscustomobject]$h
}

$script:EntryListDefault = 50   # Get-PwEntry が既定で表示する件数

function ConvertTo-PwQuery([string]$Query, $Cfg) {
    <# 検索語を、空白で区切った語の一覧 @{ Field = 項目名（$null ならすべての項目）; Text = 探す文字 } にする。
       「項目:文字」の形（例 url:example、ID:taro）なら、その項目だけを探す。項目名は Name・Label のどちらでもよく、
       タイトルは title / タイトル。項目名に当たらなければ（https://… など）、全体をふつうの語として扱う。 #>
    foreach ($word in ($Query -split '\s+' | Where-Object { $_ })) {
        $field = $null; $text = $word
        $i = $word.IndexOf(':')
        if ($i -gt 0 -and $i -lt $word.Length - 1) {
            $key = $word.Substring(0, $i)
            if ($key -in 'title', 'タイトル') { $field = 'Title' }
            else { $field = @($Cfg.Fields | Where-Object { $_.Name -eq $key -or $_.Label -eq $key } | ForEach-Object { $_.Name }) | Select-Object -First 1 }
            if ($field) { $text = $word.Substring($i + 1) }
        }
        @{ Field = $field; Text = $text }
    }
}

function Test-PwMatch($Entry, $Terms, $Cfg) {
    # すべての語が含まれれば一致（大文字小文字は区別しない）。項目を指定しない語は、タイトルかいずれかの項目に含まれればよい
    foreach ($term in @($Terms)) {
        $texts = if ($term.Field) { @($Entry.($term.Field)) } else { @($Entry.Title) + @(foreach ($f in @($Cfg.Fields)) { $Entry.($f.Name) }) }
        $hit = $false
        foreach ($t in $texts) {
            if ($t -and ([string]$t).IndexOf($term.Text, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
        }
        if (-not $hit) { return $false }
    }
    $true
}

function Get-PwEntry {
    <#
    .SYNOPSIS
      エントリを検索・一覧表示する（パスワードは含まない）。
    .DESCRIPTION
      1 件 1 行の表で、タイトル・ID・URL・更新日時を表示する。全項目は | Format-List * で見る。
      既定では先頭 50 件だけを表示し、残りがあれば件数を知らせる。全件は -All、件数は -First で指定する。
      返すのはふつうのオブジェクトなので、Sort-Object・Where-Object・Out-GridView などにそのまま渡せる。
    .PARAMETER Filter
      検索語。空白で区切ると、すべての語を含むものだけ（大文字小文字は区別しない）。
      「項目:文字」の形で、その項目だけを探す（例: url:example、id:taro、title:社内）。
    .PARAMETER All
      件数を区切らずに全件を返す。
    .PARAMETER First
      返す件数（既定 50）。
    .PARAMETER Skip
      先頭から飛ばす件数（ページ送り）。
    .EXAMPLE
      Get-PwEntry ポータル
    .EXAMPLE
      Get-PwEntry url:example.com id:taro
    .EXAMPLE
      Get-PwEntry -Skip 50 -First 50          # 51〜100 件目
    .EXAMPLE
      Get-PwEntry -All | Sort-Object Updated -Descending | Select-Object -First 10   # 最近更新した 10 件
    .EXAMPLE
      Get-PwEntry ポータル | Format-List *    # 全項目を表示
    #>
    [CmdletBinding(SupportsPaging)]
    param([Parameter(Position = 0)][string]$Filter, [switch]$All)
    $cfg = Get-PwConfig
    $keys = Get-PwEntryKeys $cfg
    # 表示する列（PowerShell は 5 列以上だと縦に並べるため、4 列までにする）
    $shown = @('Title') + @($cfg.Fields | Where-Object { -not $_.Multiline } | Select-Object -First 2 | ForEach-Object { $_.Name }) + @('Updated')
    Update-TypeData -TypeName 'PwManager.Entry' -DefaultDisplayPropertySet $shown -Force
    $terms = @(ConvertTo-PwQuery $Filter $cfg)
    $list = @(foreach ($i in Get-PwSecretInfo) {
        $e = ConvertTo-PwEntry $i.Name $i.Metadata $keys
        if ($terms.Count -and -not (Test-PwMatch $e $terms $cfg)) { continue }
        $e.PSObject.TypeNames.Insert(0, 'PwManager.Entry')
        $e
    }) | Sort-Object Title
    $list = @($list)

    $paging = $PSCmdlet.PagingParameters
    if ($paging.IncludeTotalCount) { $paging.NewTotalCount([uint64]$list.Count, 1.0) }
    $skip = [int][Math]::Min([uint64]$list.Count, $paging.Skip)
    $take = if ($All) { $list.Count } elseif ($PSBoundParameters.ContainsKey('First')) { [int][Math]::Min([uint64][int]::MaxValue, $paging.First) } else { $script:EntryListDefault }
    $end = [Math]::Min($list.Count, $skip + $take)
    for ($k = $skip; $k -lt $end; $k++) { $list[$k] }
    if (-not $All -and -not $PSBoundParameters.ContainsKey('First') -and $end -lt $list.Count) {
        # 黙って減らすと「全件のつもり」で使ってしまうので、必ず知らせる
        Write-Warning ("{0} 件のうち {1}〜{2} 件目を表示しました。全件は -All、続きは -Skip {2}、絞り込みは Get-PwEntry 検索語。" -f $list.Count, ($skip + 1), $end)
    }
}

function Get-PwPassword([string]$Name) {
    $cfg = Get-PwConfig
    Use-PwVault { Get-Secret -Vault $cfg.VaultName -Name $Name -AsPlainText }
}

function Save-PwEntry {
    <# 新規(-Name なし)または更新。-Password を省略した更新では、パスワードは変更しない。 #>
    param(
        [string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [hashtable]$Fields = @{},
        [securestring]$Password
    )
    $cfg = Get-PwConfig
    $now = Get-Date -Format $script:DateFormat
    $isNew = -not $Name
    $meta = @{}

    if ($isNew) {
        if (-not $Password -or $Password.Length -eq 0) { throw '新規登録にはパスワードが必要です。' }
        $Name = $script:SecretPrefix + [guid]::NewGuid().ToString('N')
        $meta['Created'] = $now
    } else {
        $old = @(Get-PwSecretInfo $Name)[0]
        if (-not $old) { throw "エントリが見つかりません: $Name" }
        # 設定から外した項目のデータも失わないよう、既存メタデータを引き継ぐ
        if ($old.Metadata) { foreach ($k in $old.Metadata.Keys) { $meta[$k] = $old.Metadata[$k] } }
        if (-not $meta.ContainsKey('Created')) { $meta['Created'] = $now }
    }

    $meta['Title']   = $Title.Trim()
    $meta['Updated'] = $now
    $meta['Schema']  = $script:SchemaVersion
    # 渡された項目だけを上書きする（渡されなかった項目の既存データは消さない）
    foreach ($k in @($Fields.Keys)) {
        if ($k -notmatch '^[A-Za-z][A-Za-z0-9_]*$' -or $script:ReservedKeys -contains $k) {
            throw "項目名 '$k' は使えません。"
        }
        $v = $Fields[$k]
        $meta[$k] = if ($null -eq $v) { '' } else { ([string]$v).Trim() }
    }

    $pwChanged = $Password -and $Password.Length -gt 0
    Use-PwVault {
        if ($pwChanged) { Set-Secret -Vault $cfg.VaultName -Name $Name -Secret $Password -Metadata $meta }
        else { Set-SecretInfo -Vault $cfg.VaultName -Name $Name -Metadata $meta }
    }

    $action = if ($isNew) { 'ADD' } elseif ($pwChanged) { 'UPDATE+PW' } else { 'UPDATE' }
    Write-PwAudit $action "[$Name]"   # タイトルは書かない（ログは暗号化されないため、使っているサービスが分からないように）
    $Name
}

function Remove-PwEntry {
    <#
    .SYNOPSIS
      エントリを削除する（確認あり。戻すにはバックアップからの復元が必要）。
    .DESCRIPTION
      PwManager の画面を閉じてから実行する。
    .PARAMETER Query
      対象の検索語（Get-PwEntry と同じ）。タイトルが完全に一致すればそれ、候補が複数なら選ぶ画面が出る。
    .PARAMETER Name
      対象の ID（pwm:…）。Get-PwEntry の結果をパイプで渡すと使われる。
    .EXAMPLE
      Remove-PwEntry 旧システム
    .EXAMPLE
      Get-PwEntry テスト | Remove-PwEntry     # 一致したものを 1 件ずつ確認して削除
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Query')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Query')][string]$Query,
        [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName = 'Name')][string]$Name
    )
    begin { Assert-PwGuiClosed; $cfg = Get-PwConfig }
    process {
        if ($PSCmdlet.ParameterSetName -eq 'Query') {
            $entry = Resolve-PwEntry $Query
            if (-not $entry) { return }
            $Name = $entry.Name
        }
        $info = @(Get-PwSecretInfo $Name)
        if ($info.Count -eq 0) { throw "エントリが見つかりません: $Name" }
        $m = $info[0].Metadata
        $title = if ($m -and $m.ContainsKey('Title')) { [string]$m['Title'] } else { $Name }
        if ($PSCmdlet.ShouldProcess($title, '削除')) {
            Remove-Secret -Vault $cfg.VaultName -Name $Name
            Write-PwAudit 'DELETE' "[$Name]"
        }
    }
}


#region マスターパスワード

$script:MasterPasswordMinLength = 12

function Test-PwSecureStringEqual([securestring]$A, [securestring]$B) {
    # 2 つの SecureString が同じかを、平文の文字列を作らずに比べる（1 文字ずつ、大文字小文字も区別）。
    # 比べるために一時的に取り出した領域は、ZeroFreeBSTR でゼロにしてから解放する
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    if ($A.Length -ne $B.Length) { return $false }
    $M = [Runtime.InteropServices.Marshal]
    $pa = [IntPtr]::Zero; $pb = [IntPtr]::Zero
    try {
        $pa = $M::SecureStringToBSTR($A)
        $pb = $M::SecureStringToBSTR($B)
        $same = $true
        for ($i = 0; $i -lt $A.Length; $i++) {
            if ($M::ReadInt16($pa, $i * 2) -ne $M::ReadInt16($pb, $i * 2)) { $same = $false }   # 途中で抜けない（比べる時間を一定にする）
        }
        $same
    } finally {
        if ($pa -ne [IntPtr]::Zero) { $M::ZeroFreeBSTR($pa) }
        if ($pb -ne [IntPtr]::Zero) { $M::ZeroFreeBSTR($pb) }
    }
}

function Test-PwMasterPasswordRule([securestring]$New, [securestring]$Confirm, [securestring]$Current) {
    # 新しいマスターパスワードの確認。問題があればその理由を、無ければ $null を返す（平文の文字列は作らない）
    if (-not (Test-PwSecureStringEqual $New $Confirm)) { return '新しいパスワードが一致しません。' }
    if ($New.Length -lt $script:MasterPasswordMinLength) { return "$($script:MasterPasswordMinLength) 文字以上にしてください。" }
    if ($Current -and (Test-PwSecureStringEqual $New $Current)) { return '今のパスワードと同じです。' }
    $null
}

function Read-PwNewMasterPassword([securestring]$Current) {
    # コンソールで新しいマスターパスワードを 2 回入力してもらう（条件を満たすまで繰り返す）
    while ($true) {
        $p1 = Read-Host '新しいマスターパスワード' -AsSecureString
        $p2 = Read-Host '確認のためもう一度' -AsSecureString
        $problem = Test-PwMasterPasswordRule $p1 $p2 $Current
        if (-not $problem) { return $p1 }
        Write-Warning $problem
    }
}

function Set-PwMasterPassword {
    <#
    .SYNOPSIS
      マスターパスワードを変更する（忘れたときは -UseRecoveryKey）。
    .DESCRIPTION
      保存済みのデータもバックアップも、そのまま使える。
      保管庫キーを新しいマスターパスワードで包み直すだけなので、すぐに終わり、一時ファイルも作らない。
      バックアップは回復キーで開くので、変更前のバックアップも影響を受けない。
      マスターパスワードを忘れたときは -UseRecoveryKey を付けると、今のパスワードの代わりに回復キーで変更できる。
      PwManager の画面が別に開いているときは実行できない（画面の ≡ →「マスターパスワードの変更」を使うこと）。
    .PARAMETER Current
      今のマスターパスワード（SecureString）。省略すると入力を求める。
    .PARAMETER UseRecoveryKey
      今のマスターパスワードの代わりに、回復キーで変更する（忘れたとき）。
    .PARAMETER RecoveryKey
      回復キー（SecureString）。省略すると入力を求める。
    .PARAMETER New
      新しいマスターパスワード（SecureString）。省略すると 2 回入力を求める。
    .EXAMPLE
      Set-PwMasterPassword                    # 今のパスワードと新しいパスワードを入力する
    .EXAMPLE
      Set-PwMasterPassword -UseRecoveryKey    # マスターパスワードを忘れたとき
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Current')]
    param(
        [Parameter(ParameterSetName = 'Current')][securestring]$Current,
        [Parameter(ParameterSetName = 'Recovery', Mandatory)][switch]$UseRecoveryKey,
        [Parameter(ParameterSetName = 'Recovery')][securestring]$RecoveryKey,
        [securestring]$New
    )
    Assert-PwGuiClosed
    if ($UseRecoveryKey) {
        if (-not $RecoveryKey) { $RecoveryKey = Read-Host '回復キー' -AsSecureString }
        $vk = Unprotect-PwRecovery (Read-PwKeyFile).Recovery $RecoveryKey
    } else {
        if (-not $Current) { $Current = Read-Host '今のマスターパスワード' -AsSecureString }
        try { $vk = Get-PwVaultKey $Current }
        catch { throw "マスターパスワードを変更できませんでした。`n$($_.Exception.Message)" }
    }
    try {
        if ($New) {
            $problem = Test-PwMasterPasswordRule $New $New $Current
            if ($problem) { throw $problem }
        } else {
            Write-Host "新しいマスターパスワード: $($script:MasterPasswordMinLength) 文字以上で、ほかでは使っていないもの"
            $New = Read-PwNewMasterPassword $Current
        }
        if (-not $PSCmdlet.ShouldProcess('マスターパスワード', '変更')) { return }
        Write-PwKeyFile $vk $New (Read-PwKeyFile).Recovery
        Unlock-PwVault (ConvertTo-PwStorePassword $vk)
    } finally { Clear-PwBytes $vk }
    Remove-Item -LiteralPath $script:UnlockFailPath -Force -ErrorAction SilentlyContinue
    Write-PwAudit 'MASTERPW' $(if ($UseRecoveryKey) { '回復キーで変更' } else { '変更' })
    $true
}

#endregion
