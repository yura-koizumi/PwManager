# Setup.ps1 - 初期設定とショートカット
# （PwManager.psm1 から読み込まれる）


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

