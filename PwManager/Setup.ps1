# Setup.ps1 - 初期設定とショートカット
# （PwManager.psm1 から読み込まれる）

function Initialize-PwManager {
    <#
    .SYNOPSIS
      初期設定をする（Install.bat から呼ばれる）。
    .DESCRIPTION
      設定ファイルの作成・保管庫の登録と、初回だけマスターパスワードの設定と回復キーの発行をする。
      保管庫がすでにあれば、そのまま使う。
    .EXAMPLE
      Initialize-PwManager
    #>
    [CmdletBinding()] param()
    Initialize-PwDataDir
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $script:ModuleRoot 'config.default.json') -Destination $script:ConfigPath
        Write-Host "設定ファイルを作成しました: $($script:ConfigPath)"
    }
    $cfg = Get-PwConfig
    Register-PwVaultIfMissing $cfg

    if (Test-Path -LiteralPath (Join-Path $script:StoreRoot 'localstore')) {
        if (-not (Test-Path -LiteralPath $script:KeyPath)) {
            throw ("保管庫はありますが、保管庫キーのファイルがありません: $($script:KeyPath)`n" +
                   'バックアップがあれば Restore-PwVault で復元してください。以前のベータ版で作った保管庫なら、Uninstall.bat でデータを削除してから、もう一度インストールしてください。')
        }
        Write-Host '既存の保管庫を使います（マスターパスワードはこれまでと同じです）。'
        return
    }

    Write-Host ''
    Write-Host 'マスターパスワードを設定します。' -ForegroundColor Cyan
    Write-Host "  ・$($script:MasterPasswordMinLength) 文字以上、ほかで使っていないもの（長めのフレーズがおすすめ）"
    $p1 = Read-PwNewMasterPassword
    $set = New-PwVaultKeySet $p1
    try {
        # ロックされているときに SecretStore 自身がパスワードを尋ねないようにする（尋ねるのは PwManager。保管庫キーは人が入力しない）
        Set-SecretStoreConfiguration -Scope CurrentUser -Authentication Password -Interaction None `
            -PasswordTimeout 900 -Password $set.StorePassword -Confirm:$false
    } catch {
        Remove-Item -LiteralPath $script:KeyPath -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host '保管庫を作成しました。' -ForegroundColor Green
    [void](Show-PwRecoveryKey $set.RecoveryKey)
}

function Install-PwShortcut {
    <#
    .SYNOPSIS
      デスクトップとスタートメニューに起動用のショートカットを作る（Install.bat から呼ばれる）。
    .EXAMPLE
      Install-PwShortcut     # ショートカットを消してしまったとき
    #>
    [CmdletBinding()] param()
    $cmd = Get-PwLaunchCommand
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
        $lnk = $shell.CreateShortcut((Join-Path $dir 'PwManager.lnk'))
        $lnk.TargetPath       = $cmd.File
        $lnk.Arguments        = $cmd.Arguments
        $lnk.WorkingDirectory = $script:ModuleRoot
        $lnk.IconLocation     = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',47'
        $lnk.Description      = 'PwManager パスワード管理'
        $lnk.Save()
        Write-Host "ショートカットを作成しました: $($lnk.FullName)"
    }
}

function Get-PwLaunchCommand([string]$Extra) {
    # ショートカットと同じ起動方法（コンソールを出さずに Launch.ps1 を実行する）
    # conhost 経由にするのは、Windows ターミナルが既定でもウィンドウを隠せるようにするため
    $launch = Join-Path $script:ModuleRoot 'Launch.ps1'
    @{
        File      = Join-Path $env:SystemRoot 'System32\conhost.exe'
        Arguments = ("powershell.exe -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$launch`" $Extra").TrimEnd()
    }
}

function Start-PwLauncher([switch]$Locked) {
    # ロックしたあと、新しいプロセスで画面を開き直す
    $cmd = Get-PwLaunchCommand $(if ($Locked) { '-Locked' })
    Start-Process -FilePath $cmd.File -ArgumentList $cmd.Arguments -WindowStyle Hidden
}
