<#
Uctan uca gecikme olcumu (PC ekrani -> telefon ekrani).

Sanal ekranin ust seridine PC saatini (ms, 16 bit) siyah/beyaz hucreler olarak
cizen bir pencere acar. Telefonda ekran goruntusu alinir; goruntudeki saat
degeri ile goruntunun alindigi an (telefon saati, PC saatine cevrilmis)
arasindaki fark gecikmedir. Telefon-PC saat farki adb ile olculur (+-10 ms).

Kullanim: .\latency_test.ps1 [-Samples 8] [-Display \\.\DISPLAY9]
Yayinin (stream.ps1) ve telefondaki uygulamanin acik olmasi gerekir.
#>
param([int]$Samples = 8, [string]$Display = '', [int]$Bits = 16)

$ErrorActionPreference = 'Continue'
$Root = Split-Path $PSScriptRoot
$adb = @((Join-Path $Root 'tools\android-sdk\platform-tools\adb.exe'), 'C:\platform-tools\adb.exe') | ? { Test-Path $_ } | Select -First 1
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function NowMs { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

# Sanal ekrani bul (varsayilan: ana ekran olmayan en sagdaki ekran)
$screens = [System.Windows.Forms.Screen]::AllScreens
$scr = if ($Display) { $screens | ? DeviceName -eq $Display } else { $screens | ? { -not $_.Primary } | Sort { $_.Bounds.X } | Select -Last 1 }
if (-not $scr) { throw 'Sanal ekran bulunamadi.' }
Write-Host "Saat penceresi: $($scr.DeviceName) $($scr.Bounds)"

# Saat penceresi ayri bir surecte calisir (bu betik olcum yaparken donmasin diye).
$clockScript = @"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$f = New-Object Windows.Forms.Form
`$f.FormBorderStyle = 'None'; `$f.TopMost = `$true; `$f.StartPosition = 'Manual'; `$f.ShowInTaskbar = `$false
`$f.Location = New-Object Drawing.Point($($scr.Bounds.X), $($scr.Bounds.Y))
`$f.Size = New-Object Drawing.Size($($scr.Bounds.Width), [int]($($scr.Bounds.Height) / 8))
`$f.BackColor = 'Black'
`$prop = [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance'); `$prop.SetValue(`$f, `$true, `$null)
`$f.Add_Paint({ param(`$s, `$e)
    `$ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    `$w = `$f.ClientSize.Width / $Bits; `$h = `$f.ClientSize.Height
    for (`$i = 0; `$i -lt $Bits; `$i++) {
        `$bit = (`$ms -shr ($Bits - 1 - `$i)) -band 1
        `$b = if (`$bit) { [Drawing.Brushes]::White } else { [Drawing.Brushes]::Black }
        `$e.Graphics.FillRectangle(`$b, [float](`$i * `$w), [float]0, [float]`$w, [float]`$h)
    }
})
`$f.Show()
while (`$f.Visible) { `$f.Invalidate(); [Windows.Forms.Application]::DoEvents(); [Threading.Thread]::Sleep(1) }
"@
$clock = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $clockScript
Start-Sleep 2

try {
    # Telefon - PC saat farki: en kisa gidis-donuslu olcumu kullan.
    $best = $null
    for ($i = 0; $i -lt 10; $i++) {
        $a = NowMs; $p = [long](& $adb shell 'date +%s%3N').Trim(); $b = NowMs
        $rtt = $b - $a
        if (-not $best -or $rtt -lt $best.Rtt) { $best = @{ Rtt = $rtt; Offset = $p - ($a + $b) / 2 } }
    }
    Write-Host ("Saat farki (telefon-PC): {0:F0} ms (+-{1:F0} ms)" -f $best.Offset, ($best.Rtt / 2))

    $tmp = Join-Path $env:TEMP 'dt_lat.raw'
    $results = @()
    for ($n = 0; $n -lt $Samples; $n++) {
        # Telefonda: once saati yaz, hemen ardindan ekrani yakala.
        $out = & $adb shell 'date +%s%3N; screencap /data/local/tmp/dt_lat.raw; echo ok'
        $shotPhone = [long]($out | Select -First 1).Trim()
        & $adb pull /data/local/tmp/dt_lat.raw $tmp 2>&1 | Out-Null
        $raw = [IO.File]::ReadAllBytes($tmp)
        $w = [BitConverter]::ToInt32($raw, 0); $h = [BitConverter]::ToInt32($raw, 4)
        $off = $raw.Length - $w * $h * 4

        # Goruntu yatay; video, sol kenardaki kamera boslugundan (~75 px) sonra baslar.
        $y = 30
        $row = 0..($w - 1) | % { $o = $off + ($y * $w + $_) * 4; [int]$raw[$o] + $raw[$o + 1] + $raw[$o + 2] }
        $videoLeft = 75 * $w / 2340
        $cell = ($w - $videoLeft) / $Bits
        $val = 0
        for ($i = 0; $i -lt $Bits; $i++) {
            $x = [int]($videoLeft + ($i + 0.5) * $cell)
            $bit = if ($row[$x] -gt 384) { 1 } else { 0 }
            $val = ($val -shl 1) -bor $bit
        }
        $shotPc = $shotPhone - $best.Offset
        $mask = [long][math]::Pow(2, $Bits)
        $lat = (([long]$shotPc % $mask) - $val + $mask) % $mask
        $results += $lat
        Write-Host ("Ornek {0}: gecikme {1} ms" -f ($n + 1), $lat)
        Start-Sleep -Milliseconds 300
    }
    $s = $results | Sort
    Write-Host ("Sonuc: min {0} ms, medyan {1} ms, maks {2} ms" -f $s[0], $s[[int]($s.Count / 2)], $s[-1]) -ForegroundColor Green
}
finally {
    Stop-Process -Id $clock.Id -Force -ErrorAction SilentlyContinue
}
