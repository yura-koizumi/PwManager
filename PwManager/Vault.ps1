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
    Write-PwAudit $action "$($meta['Title']) [$Name]"
    $Name
}

function Remove-PwEntry {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-PwConfig
    $info = Get-SecretInfo -Vault $cfg.VaultName -Name $Name | Where-Object { $_.Name -eq $Name }
    if (-not $info) { throw "エントリが見つかりません: $Name" }
    $title = if ($info.Metadata -and $info.Metadata.ContainsKey('Title')) { $info.Metadata['Title'] } else { $Name }
    if ($PSCmdlet.ShouldProcess($title, '削除')) {
        Remove-Secret -Vault $cfg.VaultName -Name $Name
        Write-PwAudit 'DELETE' "$title [$Name]"
    }
}

