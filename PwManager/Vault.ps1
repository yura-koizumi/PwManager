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

function Unlock-PwVault([securestring]$Password) {
    $cfg = Get-PwConfig
    Unlock-SecretStore -Password $Password -PasswordTimeout ([int]$cfg.UnlockTimeoutSeconds)
}

#region ロック解除の失敗（総当たり対策）
# 画面からのロック解除に続けて失敗すると、次に試せるまでの待ち時間を延ばす（ふだんの打ち間違いでは待たない）。
# 回数と最後の日時を %APPDATA%\PwManager\unlock.json に残し、次に正しく開いたときに本人へ知らせる。
# ※ 保管庫ファイルを直接狙う攻撃（オフライン攻撃）はこれでは防げない。そちらはマスターパスワードの強さで守る。

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
        Unlock-PwVault $Password
    } catch {
        $n = $before.Count + 1
        Initialize-PwDataDir
        @{ Count = $n; Last = (Get-Date -Format $script:DateFormat) } | ConvertTo-Json | Set-Content -LiteralPath $script:UnlockFailPath -Encoding UTF8
        Write-PwAudit 'UNLOCK-FAIL' "連続 $n 回目"
        throw
    }
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
    foreach ($info in @(Get-SecretInfo -Vault $cfg.VaultName -Name $pattern)) {
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

function Test-PwMatch($Entry, [string]$Query, $Cfg) {
    # 空白区切りの全単語が、タイトルまたはいずれかの項目に含まれれば一致（大文字小文字は区別しない）
    if (-not $Query) { return $true }
    $texts = @($Entry.Title) + @(foreach ($f in @($Cfg.Fields)) { $Entry.($f.Name) })
    foreach ($word in ($Query -split '\s+' | Where-Object { $_ })) {
        $hit = $false
        foreach ($t in $texts) {
            if ($t -and $t.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
        }
        if (-not $hit) { return $false }
    }
    $true
}

function Get-PwEntry {
    <# 登録済みエントリの一覧（パスワードは含まない） #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Filter)
    $cfg = Get-PwConfig
    $keys = Get-PwEntryKeys $cfg
    $list = @(foreach ($i in Get-PwSecretInfo) { ConvertTo-PwEntry $i.Name $i.Metadata $keys })
    if ($Filter) { $list = @($list | Where-Object { Test-PwMatch $_ $Filter $cfg }) }
    $list | Sort-Object Title
}

function Get-PwPassword([string]$Name) {
    $cfg = Get-PwConfig
    Get-Secret -Vault $cfg.VaultName -Name $Name -AsPlainText
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
        $old = Get-SecretInfo -Vault $cfg.VaultName -Name $Name | Where-Object { $_.Name -eq $Name }
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
    if ($pwChanged) {
        Set-Secret -Vault $cfg.VaultName -Name $Name -Secret $Password -Metadata $meta
    } else {
        Set-SecretInfo -Vault $cfg.VaultName -Name $Name -Metadata $meta
    }

    $action = if ($isNew) { 'ADD' } elseif ($pwChanged) { 'UPDATE+PW' } else { 'UPDATE' }
    Write-PwAudit $action "[$Name]"   # タイトルは書かない（ログは暗号化されないため、使っているサービスが分からないように）
    $Name
}

function Remove-PwEntry {
    <#
    .SYNOPSIS
      エントリを削除する（確認あり。戻すにはバックアップからの復元が必要）。
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
      マスターパスワードを変更する。保存済みのデータは、新しいパスワードで暗号化し直される。
    .DESCRIPTION
      変更の間だけ、変更前の保管庫を %APPDATA%\PwManager\pre-pwchange-*.zip に退避する。
      新しいパスワードで開けることを確かめたら、退避ファイル（古いパスワードで開けるもの）は削除する。
      古いパスワードが漏れた場合に、そこから中身を読まれないようにするため。残したいときは -KeepSafetyCopy を付ける。
      それまでに手で取ったバックアップは消さない（開くには変更前のパスワードが必要）。
      PwManager の画面が別に開いているときは実行できない（画面の ≡ →「マスターパスワードの変更」を使うこと）。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([securestring]$Current, [securestring]$New, [switch]$KeepSafetyCopy)
    Assert-PwGuiClosed
    if (-not $Current) { $Current = Read-Host '今のマスターパスワード' -AsSecureString }
    if ($New) {
        $problem = Test-PwMasterPasswordRule $New $New $Current
        if ($problem) { throw $problem }
    } else {
        Write-Host "新しいマスターパスワード: $($script:MasterPasswordMinLength) 文字以上で、ほかでは使っていないもの"
        $New = Read-PwNewMasterPassword $Current
    }
    if (-not $PSCmdlet.ShouldProcess('マスターパスワード', '変更')) { return }

    $safety = Save-PwVaultSafetyCopy 'pre-pwchange'
    try { Set-SecretStorePassword -Password $Current -NewPassword $New }
    catch {
        # 変わっていないので、退避ファイルは今の保管庫と同じ。残す意味がないので消す
        if ($safety) { Remove-Item -LiteralPath $safety -Force -ErrorAction SilentlyContinue }
        throw "マスターパスワードを変更できませんでした（今のパスワードが違う可能性があります）。`n$($_.Exception.Message)"
    }
    try { Unlock-PwVault $New }
    catch { throw "変更しましたが、新しいパスワードで開けませんでした。変更前の保管庫を残してあります: $safety`n$($_.Exception.Message)" }
    Write-PwAudit 'MASTERPW' '変更'

    if (-not $KeepSafetyCopy) {
        # 新しいパスワードで開けたので、古いパスワードで開ける退避ファイルは（以前のものも含めて）消す
        Get-ChildItem -LiteralPath $script:DataDir -Filter 'pre-pwchange-*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force
        $safety = $null
    }
    [pscustomobject]@{ SafetyCopy = $safety }
}

#endregion
