# DisplayTubeServer icin test istemcisi: paketleri okur, sayar, H.264 olarak kaydeder.
# Kullanim: .\test_client.ps1 [-Seconds 5] [-Out tests\from_server.h264]
param([int]$Port = 27183, [int]$Seconds = 5, [string]$Out = '')

$c = New-Object Net.Sockets.TcpClient
$c.NoDelay = $true
$c.Connect('127.0.0.1', $Port)
$s = $c.GetStream()
$fs = if ($Out) { [IO.File]::Create($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)) }

function ReadN($n) {
    $b = New-Object byte[] $n; $o = 0
    while ($o -lt $n) { $r = $s.Read($b, $o, $n - $o); if ($r -le 0) { throw 'baglanti kapandi' }; $o += $r }
    return ,$b
}

$counts = @{1 = 0; 2 = 0; 3 = 0}; $bytes = 0
$sw = [Diagnostics.Stopwatch]::StartNew(); $firstFrameMs = $null
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    $h = ReadN 5
    # [int] sart: PowerShell'de byte -shl sonucu byte'ta tasar.
    $len = ([int]$h[1] -shl 24) -bor ([int]$h[2] -shl 16) -bor ([int]$h[3] -shl 8) -bor [int]$h[4]
    $p = ReadN $len
    $counts[[int]$h[0]]++; $bytes += $len
    if ($h[0] -ne 1 -and $null -eq $firstFrameMs) { $firstFrameMs = $sw.ElapsedMilliseconds }
    if ($fs) { $fs.Write($p, 0, $len) }
}
$c.Close(); if ($fs) { $fs.Close() }
"config=$($counts[1]) anahtar=$($counts[2]) kare=$($counts[3]) toplam=$([math]::Round($bytes/1MB,1)) MB ilk_kare=${firstFrameMs}ms"
