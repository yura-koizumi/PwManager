# Config.ps1 - 設定・状態・監査ログ
# （PwManager.psm1 から読み込まれる）

function Initialize-PwDataDir {
    if (-not (Test-Path -LiteralPath $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
}

function Get-PwNow([string]$Format) {
    # 今の日時を文字列にする。Windows の地域設定（和暦など）に左右されないよう、固定の書式で作る
    [datetime]::Now.ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
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

    # 画面は有効期限の 60 秒前に再入力を求めるので、それより短いと開くたびに求め続けてしまう
    if ([int]$cfg.UnlockTimeoutSeconds -lt 120) { throw '設定 UnlockTimeoutSeconds は 120 以上にしてください。' }

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
    <#
    .SYNOPSIS
      設定ファイル（config.json）を開く。
    .DESCRIPTION
      無ければ既定値のコピーを作る。メモ帳 → 既定のアプリ → エクスプローラーの順に試し、
      使った方法（'Notepad' / 'App' / 'Explorer'）を返す。メモ帳が無い環境（Windows Sandbox など）でも止まらない。
      保存したあと、PwManager を開き直すと反映される。
    .EXAMPLE
      Edit-PwConfig
    #>
    [CmdletBinding()] param()
    Initialize-PwDataDir
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $script:ModuleRoot 'config.default.json') -Destination $script:ConfigPath
    }
    $path = $script:ConfigPath
    try { Start-Process notepad.exe -ArgumentList "`"$path`"" -ErrorAction Stop; return 'Notepad' } catch { }
    try { Start-Process -FilePath $path -ErrorAction Stop; return 'App' } catch { }
    Start-Process explorer.exe -ArgumentList "/select,`"$path`""
    'Explorer'
}

function Write-PwAudit([string]$Action, [string]$Detail) {
    # パスワードそのものは絶対に書かない
    try {
        Initialize-PwDataDir
        if ((Test-Path -LiteralPath $script:AuditPath) -and (Get-Item -LiteralPath $script:AuditPath).Length -gt $script:AuditMaxBytes) {
            Move-Item -LiteralPath $script:AuditPath -Destination ($script:AuditPath -replace '\.log$', '.old.log') -Force
        }
        $line = "{0}`t{1}`t{2}`t{3}" -f (Get-PwNow $script:DateFormat), $env:USERNAME, $Action, $Detail
        Add-Content -LiteralPath $script:AuditPath -Value $line -Encoding UTF8
    } catch { }
}

