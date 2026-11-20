# Backup.ps1 - バックアップ・復元
# （PwManager.psm1 から読み込まれる）
# バックアップの ZIP には、暗号化されたままの保管庫・設定・回復用の包み（recovery.json）を入れる。
# この PC 用の包み（Windows ユーザーに結び付いたもの）は入れない。開くには回復キーが必要。

function Save-PwArchive([string]$Zip) {
    $tmp = Join-Path $env:TEMP ('pwm-archive-' + [guid]::NewGuid().ToString('N'))
    try {
        $paths = @($script:StoreRoot)
        if (Test-Path -LiteralPath $script:ConfigPath) { $paths += $script:ConfigPath }
        if (Test-Path -LiteralPath $script:KeyPath) {
            New-Item -ItemType Directory -Path $tmp | Out-Null
            $rec = Join-Path $tmp 'recovery.json'
            [ordered]@{ Version = 1; Recovery = (Read-PwKeyFile).Recovery } | ConvertTo-Json | Set-Content -LiteralPath $rec -Encoding UTF8
            $paths += $rec
        }
        Compress-Archive -LiteralPath $paths -DestinationPath $Zip -CompressionLevel Optimal
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Backup-PwVault {
    <#
    .SYNOPSIS
      保管庫（暗号化されたまま）と設定を ZIP にバックアップする。
    .DESCRIPTION
      新しい PC への移行や、万一に備えて手で取る。戻す（Restore-PwVault）には回復キーが必要。
    .PARAMETER Destination
      保存先のフォルダー（無ければ作る）。ZIP の名前は PwManager-backup-<PC 名>-<日時>.zip。
    .EXAMPLE
      Backup-PwVault -Destination E:\Backup
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath (Join-Path $script:StoreRoot 'localstore'))) { throw "保管庫データが見つかりません: $($script:StoreRoot)\localstore" }
    [void](Read-PwKeyFile)   # キーのファイルが無ければ、回復キーで開けないバックアップになるので止める

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $zip = Join-Path $Destination ('PwManager-backup-{0}-{1}.zip' -f $env:COMPUTERNAME, (Get-PwNow 'yyyyMMdd-HHmmss'))
    Save-PwArchive $zip
    Write-PwAudit 'BACKUP' $zip
    Get-Item -LiteralPath $zip
}

function Save-PwVaultSafetyCopy([string]$Kind) {
    # 保管庫を大きく変える前に、%APPDATA%\PwManager\<Kind>-<日時>.zip に退避する（バックアップと同じ形式。保管庫が無ければ何もしない）
    if (-not (Test-Path -LiteralPath (Join-Path $script:StoreRoot 'localstore'))) { return $null }
    Initialize-PwDataDir
    $zip = Join-Path $script:DataDir ('{0}-{1}.zip' -f $Kind, (Get-PwNow 'yyyyMMdd-HHmmss-fff'))
    Save-PwArchive $zip
    $zip
}

function Assert-PwGuiClosed {
    # 別のプロセスで画面が開いていれば止める（この PowerShell 自身が画面を表示中なら問題ない）
    if ($script:PinnedConfig) { return }   # PinnedConfig は、このプロセスで画面を表示している間だけ設定される
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting($script:GuiMutexName, [ref]$m)) {
        $m.Dispose()
        throw 'PwManager の画面が開いています。画面を閉じてから、新しい PowerShell で実行してください。'
    }
}

function Restore-PwVault {
    <#
    .SYNOPSIS
      バックアップの ZIP から保管庫を復元する（回復キーが必要）。
    .DESCRIPTION
      現在の保管庫は %APPDATA%\PwManager に退避される。回復キーで開けることを確かめてから置き換える。続けて、この PC で使うマスターパスワードを設定する（以前と同じでもよい）。
      PwManager の画面を閉じてから、新しい PowerShell で実行すること。
    .PARAMETER Path
      Backup-PwVault で作った ZIP。
    .PARAMETER IncludeConfig
      設定（config.json）も戻す。
    .PARAMETER RecoveryKey
      回復キー（SecureString）。省略すると入力を求める。
    .PARAMETER NewMasterPassword
      この PC で使うマスターパスワード（SecureString）。省略すると 2 回入力を求める。
    .EXAMPLE
      Restore-PwVault -Path E:\Backup\PwManager-backup-PC01-20261118-090000.zip -IncludeConfig
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeConfig,
        [securestring]$RecoveryKey,
        [securestring]$NewMasterPassword
    )
    if ($script:PinnedConfig) { throw '復元は、PwManager の画面を閉じてから、新しい PowerShell で実行してください。' }
    Assert-PwGuiClosed
    $tmp = Join-Path $env:TEMP ('pwm-restore-' + [guid]::NewGuid().ToString('N'))
    $vk = $null
    try {
        Expand-Archive -LiteralPath $Path -DestinationPath $tmp
        $src = Join-Path $tmp 'secretmanagement\localstore'
        $recFile = Join-Path $tmp 'recovery.json'
        if (-not (Test-Path -LiteralPath $src)) { throw 'このファイルには保管庫データ (secretmanagement\localstore) が含まれていません。' }
        if (-not (Test-Path -LiteralPath $recFile)) { throw 'このファイルには回復キーで開くための情報 (recovery.json) がありません（以前のベータ版のバックアップです）。' }
        $rec = (Read-PwJson $recFile).Recovery

        if (-not $RecoveryKey) { $RecoveryKey = Read-Host '回復キー（4 文字ずつ 8 組）' -AsSecureString }
        $vk = Unprotect-PwRecovery $rec $RecoveryKey   # 回復キーが違えば、何も変えずにここで止まる
        if (-not $PSCmdlet.ShouldProcess('現在の保管庫', "$Path の内容で置き換え")) { return }
        if ($NewMasterPassword) {
            $problem = Test-PwMasterPasswordRule $NewMasterPassword $NewMasterPassword $null
            if ($problem) { throw $problem }
        } else {
            Write-Host "この PC で使うマスターパスワードを設定します（以前と同じでも構いません。$($script:MasterPasswordMinLength) 文字以上）。"
            $NewMasterPassword = Read-PwNewMasterPassword
        }

        $dst = Join-Path $script:StoreRoot 'localstore'
        $old = "$dst.old"   # 置き換えに失敗したら、これを戻す
        $safety = Save-PwVaultSafetyCopy 'pre-restore'
        if ($safety) { Write-Host "現在の保管庫を退避しました: $safety" }
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
        if (Test-Path -LiteralPath $dst) { Move-Item -LiteralPath $dst -Destination $old }
        try {
            # 保管庫の登録情報(secretvaultregistry)はPCごとにモジュールのパスが違うため、データ本体だけ戻す
            New-Item -ItemType Directory -Path $script:StoreRoot -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $script:StoreRoot -Recurse
            Write-PwKeyFile $vk $NewMasterPassword $rec   # 一時ファイルに書いてから置き換えるので、失敗しても今の鍵ファイルは残る
        } catch {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $dst }
            throw "復元できなかったため、元の保管庫に戻しました。`n$($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:UnlockFailPath -Force -ErrorAction SilentlyContinue

        $cfgFile = Join-Path $tmp 'config.json'
        if ($IncludeConfig -and (Test-Path -LiteralPath $cfgFile)) {
            Copy-Item -LiteralPath $cfgFile -Destination $script:ConfigPath -Force
            Write-Host '設定も復元しました。'
        }
        Register-PwVaultIfMissing (Get-PwConfig)
        Write-PwAudit 'RESTORE' $Path
        Write-Host '復元しました。PowerShell を開き直してから、いま設定したマスターパスワードで開いてください。' -ForegroundColor Green
    } finally {
        Clear-PwBytes $vk
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
