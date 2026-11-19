# Password.ps1 - パスワード生成
# （PwManager.psm1 から読み込まれる）


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

