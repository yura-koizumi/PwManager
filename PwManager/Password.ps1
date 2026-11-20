# Password.ps1 - パスワード生成
# （PwManager.psm1 から読み込まれる）

$script:PasswordMinLength = 4     # 4 桁の暗証番号も作れるように
$script:PasswordMaxLength = 128

function New-PwPassword {
    <#
    .SYNOPSIS
      パスワードを生成する（保管庫には保存しない）。
    .DESCRIPTION
      暗号論的乱数で作る。使う文字の種類（大文字・小文字・数字・記号）を最低 1 文字ずつ含む。
      英字と数字が混ざるときは、紛らわしい文字（0/O、1/l/I）を使わない。
      サイトの決まりに合わせて、長さ・英数字のみ・数字のみ・使える記号を指定できる。
      省略した値は設定の PasswordGenerator（既定: 20 文字・記号あり）。
    .PARAMETER Length
      長さ（4〜128）。
    .PARAMETER NoSymbols
      英数字のみ（記号を使わない）。
    .PARAMETER DigitsOnly
      数字のみ（暗証番号など。0〜9 をすべて使う）。
    .PARAMETER SymbolChars
      使ってよい記号（サイトが決めた記号しか使えないとき）。例: '!@#'
    .PARAMETER AsSecureString
      SecureString で返す（New-PwEntry / Set-PwEntry の -Password に渡すとき）。
    .EXAMPLE
      New-PwPassword -Length 24
    .EXAMPLE
      New-PwPassword -Length 12 -NoSymbols          # 英数字のみ 12 文字
    .EXAMPLE
      New-PwPassword -Length 4 -DigitsOnly          # 4 桁の暗証番号
    .EXAMPLE
      New-PwPassword -SymbolChars '!@#'             # 記号は ! @ # だけ
    .EXAMPLE
      New-PwEntry 'Amazon' -Password (New-PwPassword -Length 16 -NoSymbols -AsSecureString)
    #>
    [CmdletBinding()]
    param(
        [int]$Length,
        [switch]$NoSymbols,
        [switch]$DigitsOnly,
        [string]$SymbolChars,
        [switch]$AsSecureString
    )
    $g = (Get-PwConfig).PasswordGenerator
    if (-not $PSBoundParameters.ContainsKey('Length')) { $Length = [int]$g.Length }
    if ($Length -lt $script:PasswordMinLength -or $Length -gt $script:PasswordMaxLength) {
        throw "パスワードの長さは $($script:PasswordMinLength)〜$($script:PasswordMaxLength) 文字にしてください。"
    }

    if ($DigitsOnly) {
        $sets = @('0123456789')
    } else {
        $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789')
        if (-not $NoSymbols) {
            $sym = if ($PSBoundParameters.ContainsKey('SymbolChars')) { $SymbolChars } elseif ($g.Symbols) { [string]$g.SymbolChars } else { '' }
            # 英数字・空白・制御文字は記号として扱わない（重複も除く）
            $sym = -join @($sym.ToCharArray() | Where-Object { $_ -match '[\p{P}\p{S}]' -and [int]$_ -lt 128 } | Select-Object -Unique)
            if ($sym) { $sets += $sym }
            elseif ($PSBoundParameters.ContainsKey('SymbolChars')) {
                throw '-SymbolChars に記号がありません（英数字・空白・全角文字は記号として使いません）。記号を使わないときは -NoSymbols を指定してください。'
            }
        }
    }
    if ($Length -lt $sets.Count) { throw "この文字の種類では、長さを $($sets.Count) 文字以上にしてください。" }
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
        if ($AsSecureString) {
            $s = New-Object System.Security.SecureString
            foreach ($c in $chars) { $s.AppendChar($c) }
            $s.MakeReadOnly()
            $s
        } else { -join $chars }
        $chars.Clear()
    } finally { $rng.Dispose() }
}
