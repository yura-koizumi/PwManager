# Backup.ps1 - バックアップ・復元
# （PwManager.psm1 から読み込まれる）

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
        # 同じ保存先をほかの PC と共用していても、この PC のバックアップだけを数えて消す
        $mine = '^PwManager-backup-{0}-\d{{8}}-\d{{6}}\.zip$' -f [regex]::Escape($env:COMPUTERNAME)
        Get-ChildItem -LiteralPath $Destination -Filter 'PwManager-backup-*.zip' |
            Where-Object { $_.Name -match $mine } |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep |
            Remove-Item -Force
    }
    Set-PwStateValue 'LastBackup' (Get-Date -Format $script:DateFormat)
    Write-PwAudit 'BACKUP' $zip
    Get-Item -LiteralPath $zip
}

function Save-PwVaultSafetyCopy([string]$Kind) {
    # 保管庫を大きく変える前に、%APPDATA%\PwManager\<Kind>-<日時>.zip に退避する（保管庫が無ければ何もしない）
    $src = Join-Path $script:StoreRoot 'localstore'
    if (-not (Test-Path -LiteralPath $src)) { return $null }
    Initialize-PwDataDir
    $zip = Join-Path $script:DataDir ('{0}-{1}.zip' -f $Kind, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Compress-Archive -LiteralPath $src -DestinationPath $zip
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
      Backup-PwVault で作った ZIP から保管庫を復元する。現在の保管庫は %APPDATA%\PwManager に退避される。
      PwManager の画面を閉じてから、新しい PowerShell で実行すること。
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeConfig
    )
    if ($script:PinnedConfig) { throw '復元は、PwManager の画面を閉じてから、新しい PowerShell で実行してください。' }
    Assert-PwGuiClosed
    $tmp = Join-Path $env:TEMP ('pwm-restore-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $Path -DestinationPath $tmp
        $src = Join-Path $tmp 'secretmanagement\localstore'
        if (-not (Test-Path -LiteralPath $src)) { throw 'このファイルには保管庫データ (secretmanagement\localstore) が含まれていません。' }
        if (-not $PSCmdlet.ShouldProcess('現在の保管庫', "$Path の内容で置き換え")) { return }

        $dst = Join-Path $script:StoreRoot 'localstore'
        $safety = Save-PwVaultSafetyCopy 'pre-restore'
        if ($safety) {
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
