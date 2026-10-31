<#
PC tarafi gecikme olcumu: ekran yakalama -> kodlama -> paketin sunucudan cikisi.

Sanal ekrana saat penceresi (clock_window.ps1) acar, ayri bir portta tek
seferlik bir yayin baslatir (telefondaki yayini bozmaz), paketleri alip her
birinin varis zamanini kaydeder. Sonra kareleri ffmpeg ile cozup icindeki saat
degerini okur: gecikme = varis zamani - karedeki saat. Ayni saat kullanildigi
icin olcum dogrudur (saat penceresinin ekrana cizilme suresi dahil).

Kullanim: .\latency_pc.ps1 [-Seconds 6] [-Encoder h264_mf] [-Port 27184]
#>
param([int]$Seconds = 6, [string]$Encoder = '', [int]$Port = 27184, [int]$Bits = 16, [string[]]$Extra = @())

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
function NowMs { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

$scr = [System.Windows.Forms.Screen]::AllScreens | ? { -not $_.Primary } | Sort { $_.Bounds.X } | Select -Last 1
$b = $scr.Bounds
$clock = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'clock_window.ps1'), '-X', $b.X, '-Y', $b.Y, '-Width', $b.Width, '-Height', $b.Height, '-Bits', $Bits

$srvArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'stream.ps1'), '-Port', $Port, '-NoAdb', '-Once')
if ($Encoder) { $srvArgs += @('-Encoder', "`"$Encoder`"") }
$srvArgs += $Extra
$log = Join-Path $env:TEMP 'dt_latpc.log'
$srv = Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$log.out" -ArgumentList $srvArgs

try {
    for ($i = 0; $i -lt 120 -and -not (netstat -ano | Select-String ":$Port .*LISTENING"); $i++) { Start-Sleep -Milliseconds 250 }
    Get-Content "$log.out" | Select-String 'Kodlayici' | % { Write-Host $_ }

    $c = New-Object Net.Sockets.TcpClient; $c.NoDelay = $true; $c.Connect('127.0.0.1', $Port)
    $s = $c.GetStream()
    function ReadN($n) { $buf = New-Object byte[] $n; $o = 0; while ($o -lt $n) { $r = $s.Read($buf, $o, $n - $o); if ($r -le 0) { throw 'kapandi' }; $o += $r }; ,$buf }

    $h264 = Join-Path $env:TEMP 'dt_latpc.h264'
    $fs = [IO.File]::Create($h264)
    $arrivals = New-Object Collections.Generic.List[long]
    $t0 = NowMs
    while ((NowMs) - $t0 -lt $Seconds * 1000) {
        $hdr = ReadN 5
        $len = ([int]$hdr[1] -shl 24) -bor ([int]$hdr[2] -shl 16) -bor ([int]$hdr[3] -shl 8) -bor [int]$hdr[4]
        $p = ReadN $len
        $now = NowMs
        $fs.Write($p, 0, $len)
        if ($hdr[0] -ne 1) { $arrivals.Add($now) }
    }
    $fs.Close(); $c.Close()
}
finally {
    Stop-Process -Id $clock.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    if (-not $srv.HasExited) { Get-CimInstance Win32_Process -Filter "ParentProcessId=$($srv.Id)" | % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
}

# Kareleri coz: ust seridi $Bits x 1 piksele kucult, her pikselin parlakligi bir bit.
$ff = 'C:\Program Files\Softdeluxe\Free Download Manager\ffmpeg.exe'
$rawOut = Join-Path $env:TEMP 'dt_latpc.gray'
& $ff -hide_banner -loglevel error -y -f h264 -i $h264 -vf "crop=iw:ih/8:0:0,scale=$($Bits * 8):8:flags=area,crop=iw:1:0:4,format=gray" -f rawvideo $rawOut
$raw = [IO.File]::ReadAllBytes($rawOut)
$fw = $Bits * 8
$frames = [math]::Min($raw.Length / $fw, $arrivals.Count)
$mask = [long][math]::Pow(2, $Bits)
$lat = @()
for ($n = 0; $n -lt $frames; $n++) {
    $val = 0
    for ($i = 0; $i -lt $Bits; $i++) { $val = ($val -shl 1) -bor ([int]($raw[$n * $fw + $i * 8 + 4] -gt 127)) }
    $lat += (($arrivals[$n] % $mask) - $val + $mask) % $mask
}
# Ilk saniyeyi (ffmpeg acilisi) atla
$skip = [math]::Min(60, [int]($lat.Count / 3))
$s = $lat[$skip..($lat.Count - 1)] | Sort
Write-Host ("PC gecikmesi ({0} kare): min {1} ms, medyan {2} ms, p90 {3} ms, maks {4} ms" -f $s.Count, $s[0], $s[[int]($s.Count / 2)], $s[[int]($s.Count * 0.9)], $s[-1]) -ForegroundColor Green
