#Requires -Version 5.1
<#
  PwManager - SecretManagement / SecretStore を使ったローカルパスワード管理

  データの置き場所
    プログラム : このフォルダー（Install.ps1 で Documents\WindowsPowerShell\Modules\PwManager にコピー）
    設定・状態 : %APPDATA%\PwManager\        (config.json / state.json / audit.log)
    保管庫     : %LOCALAPPDATA%\Microsoft\PowerShell\secretmanagement\localstore  (SecretStore が管理・暗号化)

  エントリの保存形式（スキーマ v1）
    シークレット名 : "pwm:" + GUID       … タイトル変更や同名サービスの複数アカウントに対応するため
    シークレット本体: パスワード (SecureString)
    メタデータ      : Title, Created, Updated, Schema, および config の Fields に定義した項目
#>

$ErrorActionPreference = 'Stop'

$script:ModuleRoot    = $PSScriptRoot
$script:SecretPrefix  = 'pwm:'
$script:SchemaVersion = 1
$script:DataDir       = Join-Path $env:APPDATA 'PwManager'
$script:ConfigPath    = Join-Path $script:DataDir 'config.json'
$script:StatePath     = Join-Path $script:DataDir 'state.json'
$script:AuditPath     = Join-Path $script:DataDir 'audit.log'
$script:StoreRoot     = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\secretmanagement'
$script:ReservedKeys  = @('Name', 'Title', 'Password', 'Created', 'Updated', 'Schema')
$script:DateFormat    = 'yyyy-MM-dd HH:mm:ss'
$script:PinnedConfig  = $null   # 画面の表示中だけ設定される（Get-PwConfig 参照）

#region 設定・状態・監査ログ ---------------------------------------------------

function Initialize-PwDataDir {
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
}

function Read-PwJson([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-PwConfig {
    <# 既定値(config.default.json)にユーザー設定(config.json)を上書きして返す。
       将来、既定値に新しい項目を追加しても、ユーザー設定を書き換えずに反映される。
       画面の表示中は、起動時に読んだ設定を返す（途中で設定ファイルを書き換えても、開き直すまで反映しない）。 #>
    if ($script:PinnedConfig) { return $script:PinnedConfig }
    $cfg = @{}
    $default = Read-PwJson (Join-Path $script:ModuleRoot 'config.default.json')
    foreach ($p in $default.PSObject.Properties) { $cfg[$p.Name] = $p.Value }

    if (Test-Path -LiteralPath $script:ConfigPath) {
        try { $user = Read-PwJson $script:ConfigPath }
        catch { throw "設定ファイルの書式が正しくありません。`n$($script:ConfigPath)`n$($_.Exception.Message)" }
        if ($user) { foreach ($p in $user.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    }

    $seen = @{}
    foreach ($f in @($cfg.Fields)) {
        if (-not $f.Name -or $f.Name -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "設定 Fields の Name は英字で始まる英数字にしてください: '$($f.Name)'"
        }
        if ($script:ReservedKeys -contains $f.Name) { throw "設定 Fields の Name '$($f.Name)' は予約語のため使えません。" }
        if ($seen.ContainsKey($f.Name)) { throw "設定 Fields の Name '$($f.Name)' が重複しています。" }
        $seen[$f.Name] = $true
        if (-not $f.Label) { $f | Add-Member -NotePropertyName Label -NotePropertyValue $f.Name -Force }
    }
    $cfg
}

function Edit-PwConfig {
    <# 設定ファイルをメモ帳で開く（無ければ既定値のコピーを作る） #>
    [CmdletBinding()] param()
    Initialize-PwDataDir
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $script:ModuleRoot 'config.default.json') -Destination $script:ConfigPath
    }
    Start-Process notepad.exe -ArgumentList "`"$($script:ConfigPath)`""
}

function Get-PwState {
    if (Test-Path -LiteralPath $script:StatePath) {
        try { $s = Read-PwJson $script:StatePath; if ($s) { return $s } } catch { }
    }
    [pscustomobject]@{}
}

function Set-PwStateValue([string]$Name, $Value) {
    $s = Get-PwState
    $s | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Initialize-PwDataDir
    $s | ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Get-PwLastBackup {
    $s = Get-PwState
    if ($s.PSObject.Properties['LastBackup']) {
        try { return [datetime]::ParseExact([string]$s.LastBackup, $script:DateFormat, [Globalization.CultureInfo]::InvariantCulture) } catch { }
    }
    $null
}

function Write-PwAudit([string]$Action, [string]$Detail) {
    # パスワードそのものは絶対に書かない
    try {
        Initialize-PwDataDir
        $line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format $script:DateFormat), $env:USERNAME, $Action, $Detail
        Add-Content -LiteralPath $script:AuditPath -Value $line -Encoding UTF8
    } catch { }
}

#endregion

#region 保管庫の操作 --------------------------------------------------------------

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

function ConvertTo-PwEntry($Info, $Cfg) {
    $m = $Info.Metadata
    $get = {
        param([string]$Key)
        if ($m -and $m.ContainsKey($Key) -and $null -ne $m[$Key]) { [string]$m[$Key] } else { '' }
    }
    $h = [ordered]@{ Name = $Info.Name; Title = (& $get 'Title') }
    foreach ($f in @($Cfg.Fields)) { $h[$f.Name] = & $get $f.Name }
    $h['Created'] = & $get 'Created'
    $h['Updated'] = & $get 'Updated'
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
    $infos = @(Get-SecretInfo -Vault $cfg.VaultName -Name "$($script:SecretPrefix)*")
    $list = @(foreach ($i in $infos) { ConvertTo-PwEntry $i $cfg })
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

#endregion

#region クリップボード -------------------------------------------------------------

function Get-PwTextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
    finally { $sha.Dispose() }
}

function Set-PwClipboard([string]$Text, [switch]$Sensitive) {
    Add-Type -AssemblyName System.Windows.Forms
    $cfg = Get-PwConfig
    $data = New-Object System.Windows.Forms.DataObject
    $data.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text)
    if ($Sensitive -and $cfg.ExcludeFromClipboardHistory) {
        # Windows のクリップボード履歴(Win+V)・クラウド同期の対象外にする（Windows 標準の仕組み）
        foreach ($fmt in 'ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard') {
            $data.SetData($fmt, [System.IO.MemoryStream]::new([byte[]]@(0, 0, 0, 0)))
        }
    }
    [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 10, 100)
}

function Clear-PwClipboardIfMatch([string]$Hash) {
    # 自分がコピーした内容がまだ残っている場合だけ消す（後から別の物をコピーしていたら触らない）
    if (-not $Hash) { return $false }
    Add-Type -AssemblyName System.Windows.Forms
    try {
        $cur = [System.Windows.Forms.Clipboard]::GetText()
        if ($cur -and (Get-PwTextHash $cur) -eq $Hash) { [System.Windows.Forms.Clipboard]::Clear(); return $true }
    } catch { }
    $false
}

function Start-PwClipboardClearJob([string]$Hash, [int]$Seconds) {
    # コンソール用：別プロセスで一定時間後にクリップボードを消す
    $cmd = @"
Start-Sleep -Seconds $Seconds
Add-Type -AssemblyName System.Windows.Forms
try {
  `$t = [System.Windows.Forms.Clipboard]::GetText()
  if (`$t) {
    `$sha = [Security.Cryptography.SHA256]::Create()
    if ([BitConverter]::ToString(`$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(`$t))) -eq '$Hash') { [System.Windows.Forms.Clipboard]::Clear() }
  }
} catch { }
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', $enc
}

function Copy-PwField {
    <#
    .SYNOPSIS
      コンソールからエントリの項目をコピーする。
    .EXAMPLE
      Copy-PwField 社内ポータル            # パスワードをコピー
      Copy-PwField 社内ポータル Id         # ID をコピー
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Query,
        [Parameter(Position = 1)][string]$Field = 'Password'
    )
    $cfg = Get-PwConfig
    $hits = @(Get-PwEntry -Filter $Query)
    $exact = @($hits | Where-Object { $_.Title -eq $Query })
    if ($exact.Count -eq 1) { $hits = $exact }
    if ($hits.Count -eq 0) { throw "「$Query」に一致するエントリはありません。" }
    $entry = if ($hits.Count -eq 1) { $hits[0] } else {
        $hits | Out-GridView -Title '対象を選んで [OK] を押してください' -OutputMode Single
    }
    if (-not $entry) { return }

    if ($Field -in 'Password', 'PW', 'パスワード') {
        $text = Get-PwPassword $entry.Name; $sensitive = $true; $label = 'パスワード'
    } else {
        $def = @($cfg.Fields | Where-Object { $_.Name -eq $Field -or $_.Label -eq $Field }) | Select-Object -First 1
        if (-not $def) { throw "項目 '$Field' は設定にありません。使える項目: Password, $(($cfg.Fields | ForEach-Object Name) -join ', ')" }
        $text = [string]$entry.($def.Name); $sensitive = [bool]$def.Sensitive; $label = $def.Label
        if (-not $text) { Write-Warning "「$($entry.Title)」の $label は空です。"; return }
    }

    Set-PwClipboard -Text $text -Sensitive:$sensitive
    $sec = [int]$cfg.ClipboardClearSeconds
    if ($sensitive -and $sec -gt 0) {
        Start-PwClipboardClearJob (Get-PwTextHash $text) $sec
        Write-Host "「$($entry.Title)」の $label をコピーしました（$sec 秒後に消去）" -ForegroundColor Green
    } else {
        Write-Host "「$($entry.Title)」の $label をコピーしました" -ForegroundColor Green
    }
}

#endregion

#region パスワード生成 ------------------------------------------------------------

function New-PwPassword {
    <# 暗号論的乱数でパスワードを生成。紛らわしい文字(0/O, 1/l/I)は除外。各文字種を最低1文字含む。 #>
    [CmdletBinding()]
    param([int]$Length, [switch]$NoSymbols)
    $g = (Get-PwConfig).PasswordGenerator
    if (-not $Length) { $Length = [int]$g.Length }
    if ($Length -lt 8) { throw 'パスワードの長さは 8 文字以上にしてください。' }

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789')
    if (-not $NoSymbols -and $g.Symbols -and $g.SymbolChars) { $sets += [string]$g.SymbolChars }
    $all = -join $sets

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = New-Object byte[] 4
        $next = {
            param([int]$Max)   # 0..Max-1 を偏りなく返す（棄却サンプリング）
            $limit = 4294967296L - (4294967296L % $Max)
            do { $rng.GetBytes($buf); $v = [long][BitConverter]::ToUInt32($buf, 0) } while ($v -ge $limit)
            [int]($v % $Max)
        }
        $chars = New-Object System.Collections.Generic.List[char]
        foreach ($s in $sets) { $chars.Add($s[(& $next $s.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(& $next $all.Length)]) }
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $next ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        -join $chars
    } finally { $rng.Dispose() }
}

#endregion

#region バックアップ・復元・移行 ----------------------------------------------------

function Backup-PwVault {
    <#
    .SYNOPSIS
      保管庫（暗号化されたまま）と設定を ZIP にバックアップし、古いものを自動削除する。
    #>
    [CmdletBinding()]
    param([string]$Destination)
    $cfg = Get-PwConfig
    if (-not $Destination) { $Destination = [Environment]::ExpandEnvironmentVariables([string]$cfg.BackupFolder) }
    if (-not $Destination) { throw 'バックアップ先が未設定です。Edit-PwConfig で BackupFolder を設定するか、-Destination を指定してください。' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:StoreRoot 'localstore'))) { throw "保管庫データが見つかりません: $($script:StoreRoot)\localstore" }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $zip = Join-Path $Destination ('PwManager-backup-{0}-{1}.zip' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $paths = @($script:StoreRoot)
    if (Test-Path -LiteralPath $script:ConfigPath) { $paths += $script:ConfigPath }
    Compress-Archive -LiteralPath $paths -DestinationPath $zip -CompressionLevel Optimal

    $keep = [int]$cfg.BackupKeep
    if ($keep -gt 0) {
        Get-ChildItem -LiteralPath $Destination -Filter 'PwManager-backup-*.zip' |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep |
            Remove-Item -Force
    }
    Set-PwStateValue 'LastBackup' (Get-Date -Format $script:DateFormat)
    Write-PwAudit 'BACKUP' $zip
    Get-Item -LiteralPath $zip
}

function Restore-PwVault {
    <#
    .SYNOPSIS
      Backup-PwVault で作った ZIP から保管庫を復元する。現在の保管庫は %APPDATA%\PwManager に退避される。
      PwManager の画面を閉じてから、新しい PowerShell で実行すること。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeConfig
    )
    $tmp = Join-Path $env:TEMP ('pwm-restore-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $Path -DestinationPath $tmp
        $src = Join-Path $tmp 'secretmanagement\localstore'
        if (-not (Test-Path -LiteralPath $src)) { throw 'このファイルには保管庫データ (secretmanagement\localstore) が含まれていません。' }
        if (-not $PSCmdlet.ShouldProcess('現在の保管庫', "$Path の内容で置き換え")) { return }

        $dst = Join-Path $script:StoreRoot 'localstore'
        if (Test-Path -LiteralPath $dst) {
            Initialize-PwDataDir
            $safety = Join-Path $script:DataDir ('pre-restore-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Compress-Archive -LiteralPath $dst -DestinationPath $safety
            Write-Host "現在の保管庫を退避しました: $safety"
            Remove-Item -LiteralPath $dst -Recurse -Force
        }
        # 保管庫の登録情報(secretvaultregistry)はPCごとにモジュールのパスが違うため、データ本体だけ戻す
        New-Item -ItemType Directory -Path $script:StoreRoot -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $script:StoreRoot -Recurse

        $cfgFile = Join-Path $tmp 'config.json'
        if ($IncludeConfig -and (Test-Path -LiteralPath $cfgFile)) {
            Initialize-PwDataDir
            Copy-Item -LiteralPath $cfgFile -Destination $script:ConfigPath -Force
            Write-Host '設定も復元しました。'
        }
        Register-PwVaultIfMissing (Get-PwConfig)
        Write-PwAudit 'RESTORE' $Path
        Write-Host '復元しました。PowerShell を開き直してから使ってください（バックアップ時のマスターパスワードが必要です）。' -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Import-PwCsv {
    <#
    .SYNOPSIS
      Excel 等から書き出した CSV を取り込む。
      必須列: Title(またはタイトル/サービス) と Password(またはパスワード)。
      その他の列は、設定 Fields の Name または Label と同じ見出しなら取り込む。
      Excel の「CSV (コンマ区切り)」は -Encoding Default、「CSV UTF-8」は既定の UTF8。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('UTF8', 'Default')][string]$Encoding = 'UTF8'
    )
    $cfg = Get-PwConfig
    $rows = @(Import-Csv -LiteralPath $Path -Encoding $Encoding)
    $pick = {
        param($Row, [string[]]$Keys)
        foreach ($k in $Keys) { $p = $Row.PSObject.Properties[$k]; if ($p -and $p.Value) { return [string]$p.Value } }
        ''
    }
    $ok = 0; $skip = 0
    foreach ($r in $rows) {
        $title = & $pick $r @('Title', 'タイトル', 'サービス', 'Service', 'サービス名')
        $pw    = & $pick $r @('Password', 'パスワード', 'PW')
        if (-not $title -or -not $pw) { $skip++; continue }
        $fields = @{}
        foreach ($f in @($cfg.Fields)) { $fields[$f.Name] = & $pick $r @($f.Name, $f.Label) }
        Save-PwEntry -Title $title -Fields $fields -Password (ConvertTo-SecureString $pw -AsPlainText -Force) | Out-Null
        $ok++
    }
    Write-PwAudit 'IMPORT' "$Path ($ok 件)"
    Write-Host "$ok 件を取り込みました。（タイトルかパスワードが空でスキップ: $skip 件）" -ForegroundColor Green
    Write-Warning "取り込みが済んだら、元の CSV / Excel ファイルは削除してください（パスワードが平文で残っています）。"
}

function Export-PwCsv {
    <#
    .SYNOPSIS
      一覧を CSV に書き出す（ほかのツールへの移行用）。-IncludePassword を付けるとパスワードを平文で含める。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludePassword
    )
    $cfg = Get-PwConfig
    if ($IncludePassword -and -not $PSCmdlet.ShouldProcess($Path, 'パスワードを平文で書き出す')) { return }
    $rows = foreach ($e in @(Get-PwEntry)) {
        $h = [ordered]@{ Title = $e.Title }
        if ($IncludePassword) { $h['Password'] = Get-PwPassword $e.Name }
        foreach ($f in @($cfg.Fields)) { $h[$f.Name] = $e.($f.Name) }
        $h['Updated'] = $e.Updated
        [pscustomobject]$h
    }
    @($rows) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    Write-PwAudit $(if ($IncludePassword) { 'EXPORT+PW' } else { 'EXPORT' }) $Path
    if ($IncludePassword) { Write-Warning '平文のパスワードを含むファイルです。用が済んだらすぐに削除してください。' }
}

#endregion

#region セットアップ ---------------------------------------------------------------

function Initialize-PwManager {
    <# 設定ファイル作成・保管庫登録・（初回のみ）マスターパスワード設定 #>
    [CmdletBinding()] param()
    Initialize-PwDataDir
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $script:ModuleRoot 'config.default.json') -Destination $script:ConfigPath
        Write-Host "設定ファイルを作成しました: $($script:ConfigPath)"
    }
    $cfg = Get-PwConfig
    Register-PwVaultIfMissing $cfg

    if (Test-Path -LiteralPath (Join-Path $script:StoreRoot 'localstore')) {
        Write-Host '既存の保管庫を使います（マスターパスワードはこれまでと同じです）。'
        return
    }

    Write-Host ''
    Write-Host 'マスターパスワードを設定します。' -ForegroundColor Cyan
    Write-Host '  ・12 文字以上、ほかで使っていないもの（長めのフレーズがおすすめ）'
    Write-Host '  ・忘れると、保存したパスワードは二度と取り出せません'
    while ($true) {
        $p1 = Read-Host 'マスターパスワード' -AsSecureString
        $p2 = Read-Host '確認のためもう一度' -AsSecureString
        $a = ConvertFrom-PwSecureString $p1; $b = ConvertFrom-PwSecureString $p2
        $match = ($a -ceq $b); $len = $a.Length
        $a = $null; $b = $null
        if (-not $match) { Write-Warning '一致しません。もう一度入力してください。'; continue }
        if ($len -lt 12) { Write-Warning '12 文字以上にしてください。'; continue }
        break
    }
    Set-SecretStoreConfiguration -Scope CurrentUser -Authentication Password -Interaction Prompt `
        -PasswordTimeout 900 -Password $p1 -Confirm:$false
    Write-Host '保管庫を作成しました。' -ForegroundColor Green
}

function Install-PwShortcut {
    <# デスクトップとスタートメニューに起動用ショートカットを作る #>
    [CmdletBinding()] param()
    $launch = Join-Path $script:ModuleRoot 'Launch.ps1'
    $arguments = "powershell.exe -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$launch`""
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
        $lnk = $shell.CreateShortcut((Join-Path $dir 'PwManager.lnk'))
        # conhost 経由にするのは、Windows ターミナルが既定でもウィンドウを隠せるようにするため
        $lnk.TargetPath       = Join-Path $env:SystemRoot 'System32\conhost.exe'
        $lnk.Arguments        = $arguments
        $lnk.WorkingDirectory = $script:ModuleRoot
        $lnk.IconLocation     = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',47'
        $lnk.Description      = 'PwManager パスワード管理'
        $lnk.Save()
        Write-Host "ショートカットを作成しました: $($lnk.FullName)"
    }
}

#endregion

. (Join-Path $PSScriptRoot 'Gui.ps1')

New-Alias -Name pwm -Value Show-PwManager -Force
