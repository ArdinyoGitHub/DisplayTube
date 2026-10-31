<#
DisplayTube PC yayincisi.

Sanal ekrani ffmpeg ddagrab ile yakalar, H.264 (Annex-B) olarak kodlar ve
127.0.0.1:<Port> uzerinde TCP dinleyicisi olarak sunar. Telefon adb reverse
ile USB uzerinden baglanir. Ag (Wi-Fi / USB tethering) kullanilmaz.

Kodlayici markadan bagimsiz secilir; ilk calisan kullanilir:
  h264_amf (AMD) -> h264_nvenc (NVIDIA) -> h264_qsv (Intel)
  -> h264_mf (Windows MediaFoundation, donanim) -> h264_mf (yazilim)
  -> libx264 -> libopenh264

Kullanim:
  .\stream.ps1                         # sanal ekrani 27183 portundan yayinla
  .\stream.ps1 -ListOutputs            # ddagrab ciktilarini listele
  .\stream.ps1 -OutputIdx 0            # belirli ekran
  .\stream.ps1 -TestFile out.h264 -Seconds 10   # TCP yerine dosyaya yaz
  .\stream.ps1 -Encoder h264_mf        # kodlayiciyi elle sec
#>
param(
    [int]$Port = 27183,
    [int]$OutputIdx = -1,          # -1: en son ddagrab ciktisi (sanal ekran en son eklenir)
    [int]$Fps = 60,
    [string]$Bitrate = '12M',
    [string]$Encoder = '',
    [string]$Ffmpeg = '',
    [string]$TestFile = '',
    [int]$Seconds = 10,
    [switch]$ListOutputs,
    [switch]$NoAdb,
    [switch]$Once,
    [ValidateSet('auto','native','ffmpeg')][string]$Engine = 'auto',   # auto: once yerel program, olmazsa ffmpeg
    [string]$EncArgs = ''       # kodlayiciya eklenecek ek argumanlar (deneme icin), orn. '-scenario video_conference'
)

# ffmpeg stderr'e yazar; PowerShell 5.1 bunu hata sanmasin diye 'Continue'. Hatalar throw ile bildiriliyor.
$ErrorActionPreference = 'Continue'
$Root = Split-Path $PSScriptRoot

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "    $m" -ForegroundColor Yellow }

# Kodlayici zinciri: ad, ffmpeg argumanlari, piksel formati
$EncoderChain = @(
    @{ Name = 'h264_amf';    Label = 'h264_amf';         Pix = 'nv12';    Args = @('-c:v','h264_amf','-usage','ultralowlatency','-rc','cbr','-bf','0') },
    @{ Name = 'h264_nvenc';  Label = 'h264_nvenc';       Pix = 'nv12';    Args = @('-c:v','h264_nvenc','-preset','p1','-tune','ull','-rc','cbr','-zerolatency','1','-bf','0') },
    @{ Name = 'h264_qsv';    Label = 'h264_qsv';         Pix = 'nv12';    Args = @('-c:v','h264_qsv','-preset','veryfast','-look_ahead','0','-bf','0') },
    @{ Name = 'h264_mf';     Label = 'h264_mf (donanim)'; Pix = 'nv12';   Args = @('-c:v','h264_mf','-hw_encoding','1','-scenario','display_remoting','-rate_control','ld_vbr','-bf','0') },
    # Direct3D 12 Video Encode: markadan bagimsiz donanim kodlama (Windows 11). Bu PC'de sunucu icinde ilk kareden sonra takiliyor; bu yuzden otomatik secilmez, sadece -Encoder h264_d3d12va ile.
    @{ Name = 'h264_d3d12va'; Label = 'h264_d3d12va';    Pix = 'nv12'; Auto = $false;
       Pre = @('-init_hw_device','d3d12va=dt12','-filter_hw_device','dt12'); Vf = 'hwupload';
       Args = @('-c:v','h264_d3d12va','-async_depth','1','-rc_mode','2','-bf','0') },
    @{ Name = 'h264_mf';     Label = 'h264_mf (yazilim)'; Pix = 'nv12';   Args = @('-c:v','h264_mf','-scenario','display_remoting','-rate_control','ld_vbr','-bf','0') },
    @{ Name = 'libx264';     Label = 'libx264';          Pix = 'yuv420p'; Args = @('-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-bf','0') },
    @{ Name = 'libopenh264'; Label = 'libopenh264';      Pix = 'yuv420p'; Args = @('-c:v','libopenh264') }
)

function Find-FfmpegCandidates {
    $c = @()
    if ($Ffmpeg) { return @($Ffmpeg) }
    $c += Join-Path $Root 'tools\ffmpeg\bin\ffmpeg.exe'
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { $c += $cmd.Source }
    $c += 'C:\Program Files\Softdeluxe\Free Download Manager\ffmpeg.exe'
    $c += 'C:\Program Files\Krita (x64)\bin\ffmpeg.exe'
    return $c | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

function Has-Ddagrab($ff) {
    # ddagrab bir filtre; kullanmak icin lavfi girdi aygiti da gerekli.
    [bool](& $ff -hide_banner -filters 2>&1 | Select-String '\bddagrab\b') -and
    [bool](& $ff -hide_banner -devices 2>&1 | Select-String '\blavfi\b')
}

# Bazi kodlayicilar girdi oncesi donanim aygiti (Pre) ve cikis filtresi (Vf) ister.
function Encoder-Pre($enc) { if ($enc.Pre) { $enc.Pre } else { @() } }
function Encoder-Vf($enc)  { if ($enc.Vf) { @('-vf', $enc.Vf) } else { @() } }

function Test-Encoder($ff, $enc) {
    # 1080p tek kare kodla; donanim yoksa ya da surucu desteklemiyorsa hata verir.
    $a = @('-hide_banner','-loglevel','error') + (Encoder-Pre $enc) +
         @('-f','lavfi','-i',"color=c=black:s=1920x1080:r=$Fps,format=$($enc.Pix)",'-frames:v','3') +
         (Encoder-Vf $enc) + $enc.Args + @('-b:v',$Bitrate,'-f','null','-')
    & $ff @a 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Select-Pipeline {
    Step 'ffmpeg ve kodlayici secimi'
    $ffs = @(Find-FfmpegCandidates | Where-Object { Has-Ddagrab $_ })
    if (-not $ffs) { throw 'ddagrab destekli ffmpeg bulunamadi (tools\ffmpeg\bin\ffmpeg.exe ya da PATH).' }
    $chain = if ($Encoder) { $EncoderChain | Where-Object { $_.Name -eq $Encoder -or $_.Label -eq $Encoder } } else { $EncoderChain | Where-Object { $_.Auto -ne $false } }
    foreach ($enc in $chain) {
        foreach ($ff in $ffs) {
            $has = [bool](& $ff -hide_banner -encoders 2>&1 | Select-String " $($enc.Name) ")
            if (-not $has) { continue }
            if (Test-Encoder $ff $enc) {
                Ok "Kodlayici: $($enc.Label)"
                Ok "ffmpeg: $ff"
                return @{ Ffmpeg = $ff; Enc = $enc }
            }
            Warn "$($enc.Label) bu sistemde calismadi, siradakine geciliyor."
        }
    }
    throw 'Calisan bir H.264 kodlayici bulunamadi.'
}

function Get-Outputs($ff) {
    $tmp = Join-Path $env:TEMP 'displaytube_probe.bmp'
    $list = @()
    for ($i = 0; $i -lt 8; $i++) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        & $ff -hide_banner -loglevel error -y -f lavfi -i "ddagrab=output_idx=${i}:framerate=5,hwdownload,format=bgra" -frames:v 1 $tmp 2>&1 | Out-Null
        if (-not (Test-Path $tmp)) { break }
        $info = & $ff -hide_banner -i $tmp 2>&1 | Select-String '(\d{3,5})x(\d{3,5})' | Select-Object -First 1
        $size = if ($info) { $info.Matches[0].Value } else { '?' }
        $list += [pscustomobject]@{ Index = $i; Size = $size }
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    return $list
}

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @((Join-Path $Root 'tools\android-sdk\platform-tools\adb.exe'), 'C:\platform-tools\adb.exe',
                     "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe")) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------

# --- Yerel motor (DisplayTubeCapture: Desktop Duplication + GPU donusum + MF donanim kodlayici) ---
# ffmpeg yoluna gore PC tarafi gecikme ~75 ms -> ~23 ms. Bu sistemde calismazsa ffmpeg'e dusulur.
if ($Engine -ne 'ffmpeg' -and -not $TestFile -and -not $ListOutputs) {
    $nativeExe = Join-Path $PSScriptRoot 'DisplayTubeCapture\bin\Release\net8.0\DisplayTubeCapture.exe'
    if (-not (Test-Path $nativeExe) -and (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Step 'Yerel yakalama programi derleniyor'
        dotnet build (Join-Path $PSScriptRoot 'DisplayTubeCapture') -c Release -nologo -v q | Out-Null
    }
    if (Test-Path $nativeExe) {
        Step 'Yerel motor deneniyor'
        $test = & $nativeExe --selftest --fps $Fps 2>$null
        if ($LASTEXITCODE -eq 0) {
            Ok "Yerel motor: $test"
            $bps = [int]([double]($Bitrate -replace '[MmKk]$','') * $(if ($Bitrate -match '[Mm]$') { 1e6 } elseif ($Bitrate -match '[Kk]$') { 1e3 } else { 1 }))
            $nArgs = @('--port', $Port, '--display', 'auto', '--fps', $Fps, '--bitrate', $bps)
            if (-not $NoAdb) { $adb = Find-Adb; if ($adb) { $nArgs += @('--adb', $adb) } }
            if ($Once) { $nArgs += '--once' }
            & $nativeExe @nArgs
            return
        }
        Warn "Yerel motor bu sistemde calismadi ($test), ffmpeg yoluna geciliyor."
    } elseif ($Engine -eq 'native') { throw "Yerel program yok: $nativeExe" }
    if ($Engine -eq 'native') { throw 'Yerel motor calismadi.' }
}
$sel = Select-Pipeline
$ff = $sel.Ffmpeg; $enc = $sel.Enc

if ($ListOutputs) { Get-Outputs $ff | Format-Table -AutoSize; return }

# Sunucu modunda ekran sirasi (output_idx) DisplayTubeServer tarafindan her ffmpeg
# baslangicinda sanal ekranin adindan yeniden hesaplanir: surucu yeniden yuklenince
# ya da ekran duzeni degisince sabit bir sira yanlis ekrana isaret edebilir.
$idxToken = if ($OutputIdx -ge 0) { "$OutputIdx" } else { '{OUTPUT_IDX}' }
if ($TestFile -and $OutputIdx -lt 0) {
    $outputs = Get-Outputs $ff
    if (-not $outputs) { throw 'ddagrab hicbir ekrani yakalayamadi.' }
    $idxToken = "$(($outputs | Select-Object -Last 1).Index)"
}
Step "Ekran: $(if ($idxToken -eq '{OUTPUT_IDX}') { 'sanal ekran (otomatik)' } else { "output_idx $idxToken" }), $Fps FPS, $Bitrate"

$bufsize = $Bitrate  # ~1 saniyelik tampon degil; dusuk gecikme icin kucuk tutuluyor
# BGRA -> NV12 donusumu CPU'da yapiliyor ve en pahali adim. flags=neighbor, varsayilan
# (bicubic) yola gore ~%40 daha az CPU ve 1080p60'a yetisiyor; bedeli renk kenarlarinda
# hafif keskinlik. (Bu ffmpeg derlemelerinde scale_d3d11 calismiyor; GPU'da donusum sonraki adim.)
$filter = "ddagrab=output_idx=${idxToken}:framerate=${Fps}:draw_mouse=1,hwdownload,format=bgra,scale=flags=neighbor,format=$($enc.Pix)"
$common = @('-hide_banner','-loglevel','warning','-filter_threads','4') + (Encoder-Pre $enc) +
          @('-f','lavfi','-i',$filter) + (Encoder-Vf $enc) + $enc.Args + @($EncArgs -split ' ' | ? { $_ }) + @(
            '-b:v',$Bitrate,'-maxrate',$Bitrate,'-bufsize',$bufsize,
            '-g',($Fps * 2),
            '-flush_packets','1')

if ($TestFile) {
    # ffmpeg PowerShell'in gecerli klasorunu bilmez; yolu mutlak yap.
    $TestFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestFile)
    New-Item -ItemType Directory -Force (Split-Path $TestFile) | Out-Null
    Step "Test dosyasi: $TestFile ($Seconds sn)"
    & $ff @common -stats -t $Seconds -f h264 -y $TestFile
    Ok "Yazildi: $((Get-Item $TestFile).Length) bayt"
    return
}

if (-not $NoAdb) {
    $adb = Find-Adb
    if ($adb) {
        & $adb reverse "tcp:$Port" "tcp:$Port" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "adb reverse tcp:$Port kuruldu" } else { Warn ('Telefon bagli degil; baglaninca: adb reverse tcp:{0} tcp:{0}' -f $Port) }
    } else { Warn 'adb bulunamadi; adb reverse elle kurulmali.' }
}

# TCP sunucusu (bkz. DisplayTubeServer.cs). ffmpeg derlemesinde tcp protokolu olmasa da calisir.
$serverSrc = Join-Path $PSScriptRoot 'DisplayTubeServer.cs'
$serverExe = Join-Path $PSScriptRoot 'bin\DisplayTubeServer.exe'
if (-not (Test-Path $serverExe) -or (Get-Item $serverSrc).LastWriteTime -gt (Get-Item $serverExe).LastWriteTime) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    New-Item -ItemType Directory -Force (Split-Path $serverExe) | Out-Null
    & $csc /nologo /optimize /out:$serverExe $serverSrc
    if ($LASTEXITCODE -ne 0) { throw 'DisplayTubeServer derlenemedi.' }
    Ok 'DisplayTubeServer derlendi'
}

$srvArgs = @('--ffmpeg', $ff, '--port', $Port, '--display', 'auto')
# Kablo cikip takilinca sunucu adb reverse'i kendisi yeniden kurar.
if (-not $NoAdb -and $adb) { $srvArgs += @('--adb', $adb) }
if ($Once) { $srvArgs += '--once' }
# FLV: sunucu her kareyi uzunluguyla alir ve gecikmeden telefona iletir.
& $serverExe @srvArgs -- @common '-flvflags' 'no_duration_filesize' '-f' 'flv' 'pipe:1'
