<#
DisplayTube - Adim 1 prototipini tek komutta calistirir (Windows).

  1. Virtual Display Driver kurulu degilse kurar (UAC onayi ister).
  2. Sanal ekrani genisletilmis ekran olarak acar ve cozunurlugunu ayarlar.
  3. Weylus'u sadece 127.0.0.1 uzerinde baslatir (yalnizca USB'den erisilir).
  4. Telefonu bekler, adb reverse kurar, telefonda tarayiciyi acar.
  5. -Watch ile kablo cikip takilinca 4. adimi kendiliginden tekrarlar.

Kullanim:
  .\DisplayTube.ps1                       # 1920x1080
  .\DisplayTube.ps1 -Width 2560 -Height 1440
  .\DisplayTube.ps1 -Watch                # kablo takip modu (Ctrl+C ile cik)
  .\DisplayTube.ps1 -Stop                 # Weylus'u kapat, adb reverse'i kaldir
#>
param(
    [int]$Width = 1920,
    [int]$Height = 1080,
    [int]$Port = 1701,
    [switch]$Watch,
    [switch]$Stop,
    [switch]$SoftwareEncode   # donanim kodlamasini (MediaFoundation / NVENC) kapat
)

$ErrorActionPreference = 'Stop'
$Root      = $PSScriptRoot
$VddDir    = Join-Path $Root 'VirtualDisplayDriver'
$WeylusExe = Join-Path $Root 'weylus\weylus.exe'
$Url       = "http://127.0.0.1:$Port"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct DT_DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
}
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct DT_DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
}
public static class DTDisplay {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DT_DISPLAY_DEVICE dd, uint flags);
    // "\\.\DISPLAYn|1" (1 = masaustune bagli) ya da null
    public static string FindByAdapter(string adapterName) {
        for (uint i = 0; i < 32; i++) {
            DT_DISPLAY_DEVICE dd = new DT_DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DT_DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            if (dd.DeviceString == adapterName) return dd.DeviceName + "|" + (dd.StateFlags & 1);
        }
        return null;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DT_DEVMODE dm);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string dev, ref DT_DEVMODE dm, IntPtr hwnd, int flags, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr lParam);
    // CDS_NORESET ile kaydedilen degisiklikleri uygular
    public static int ApplyPending() { return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        'C:\platform-tools\adb.exe',
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    )
    $candidates += Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter adb.exe -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    throw "adb bulunamadi. Android Platform Tools'u kur: winget install Google.PlatformTools"
}

function Get-VirtualDisplay {
    $r = [DTDisplay]::FindByAdapter('Virtual Display Driver')
    if (-not $r) { return $null }
    $name, $attached = $r -split '\|'
    return [pscustomobject]@{ Name = $name; Attached = ($attached -eq '1') }
}

function Ensure-Driver {
    Step 'Sanal ekran surucusu'
    $dev = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.HardwareID -contains 'Root\MttVDD' } | Select-Object -First 1
    if ($dev -and $dev.Status -eq 'OK') { Ok "Kurulu ($($dev.InstanceId))"; return }
    if ($dev) { throw "Surucu var ama calismiyor (durum: $($dev.Status)). Aygit Yoneticisi'nde hata kodunu kontrol et." }

    Warn 'Kurulu degil, kuruluyor. UAC penceresinde "Evet" de.'
    $log = Join-Path $env:TEMP 'displaytube_vdd_install.log'
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$VddDir\install_vdd.ps1`"", '-DriverDir', "`"$VddDir`"", '-Log', "`"$log`"")
    Get-Content $log -ErrorAction SilentlyContinue | Select-String 'pnputil exit|root device|ERROR' | ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Seconds 2
    $dev = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.HardwareID -contains 'Root\MttVDD' } | Select-Object -First 1
    if (-not $dev -or $dev.Status -ne 'OK') { throw "Surucu kurulamadi. Gunluk: $log" }
    Ok 'Kuruldu'
}

function Ensure-Display {
    Step "Sanal ekran ${Width}x${Height}"
    if ("${Width}x${Height}" -in @('800x600', '1366x768')) {
        Warn 'Bu cozunurlukte Weylus goruntusu kayik cizgiler halinde bozulabiliyor. 1920x1080 ya da 2560x1440 onerilir.'
    }
    $vd = $null
    for ($i = 0; $i -lt 10 -and -not $vd; $i++) { $vd = Get-VirtualDisplay; if (-not $vd) { Start-Sleep 1 } }
    if (-not $vd) { throw 'Sanal ekran Windows tarafinda gorunmuyor.' }

    $dm = New-Object DT_DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
    $supported = $false
    for ($m = 0; [DTDisplay]::EnumDisplaySettings($vd.Name, $m, [ref]$dm); $m++) {
        if ($dm.dmPelsWidth -eq $Width -and $dm.dmPelsHeight -eq $Height) { $supported = $true; break }
    }
    if (-not $supported) { throw "${Width}x${Height} desteklenmiyor. C:\VirtualDisplayDriver\vdd_settings.xml dosyasina ekleyebilirsin." }

    [DTDisplay]::EnumDisplaySettings($vd.Name, -1, [ref]$dm) | Out-Null
    if ($vd.Attached -and $dm.dmPelsWidth -eq $Width -and $dm.dmPelsHeight -eq $Height) {
        Ok "Zaten hazir ($($vd.Name))"; return $vd.Name
    }
    $dm.dmPelsWidth = $Width; $dm.dmPelsHeight = $Height
    $dm.dmFields = 0x80000 -bor 0x100000                       # DM_PELSWIDTH | DM_PELSHEIGHT
    if (-not $vd.Attached) {
        # Masaustune bagli degilse ana ekranin sagina yerlestir (genislet).
        Add-Type -AssemblyName System.Windows.Forms
        $right = ([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.Bounds.Right } | Measure-Object -Maximum).Maximum
        $dm.dmPositionX = $right; $dm.dmPositionY = 0
        $dm.dmFields = $dm.dmFields -bor 0x20                  # DM_POSITION
    }
    # CDS_UPDATEREGISTRY | CDS_NORESET, ardindan tek seferde uygula
    $r = [DTDisplay]::ChangeDisplaySettingsEx($vd.Name, [ref]$dm, [IntPtr]::Zero, 0x1 -bor 0x10000000, [IntPtr]::Zero)
    if ($r -ne 0) { throw "Cozunurluk ayarlanamadi (kod $r)." }
    $r = [DTDisplay]::ApplyPending()
    if ($r -ne 0) { throw "Ekran ayari uygulanamadi (kod $r)." }

    $cur = New-Object DT_DEVMODE; $cur.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($cur)
    [DTDisplay]::EnumDisplaySettings($vd.Name, -1, [ref]$cur) | Out-Null
    if ($cur.dmPelsWidth -ne $Width -or $cur.dmPelsHeight -ne $Height) {
        throw "Cozunurluk degismedi (su an $($cur.dmPelsWidth)x$($cur.dmPelsHeight))."
    }
    Ok "Ayarlandi ($($vd.Name))"
    return $vd.Name
}

function Ensure-Weylus {
    Step 'Weylus'
    $running = Get-Process weylus -ErrorAction SilentlyContinue
    if ($running) {
        Ok "Zaten calisiyor (PID $($running[0].Id)). Ayarlarini degistirmek icin once: .\DisplayTube.ps1 -Stop"
    } else {
        if (-not (Test-Path $WeylusExe)) { throw "Weylus bulunamadi: $WeylusExe" }
        # 127.0.0.1: sadece bu PC'den ve adb reverse (USB) uzerinden erisilir, Wi-Fi agina acilmaz.
        $wArgs = @('--no-gui', '--bind-address', '127.0.0.1', '--web-port', $Port)
        # Donanim kodlama denenir; basarisiz olursa Weylus kendisi yazilim kodlamaya (x264) duser.
        if (-not $SoftwareEncode) { $wArgs += @('--try-mediafoundation', '--try-nvenc') }
        $wLog = Join-Path $env:TEMP 'displaytube_weylus.log'
        Start-Process $WeylusExe -WorkingDirectory (Split-Path $WeylusExe) -WindowStyle Hidden `
            -ArgumentList $wArgs -RedirectStandardError $wLog | Out-Null
        Ok "Baslatildi (arka planda, sadece 127.0.0.1, $(if ($SoftwareEncode) { 'yazilim' } else { 'donanim' }) kodlama). Gunluk: $wLog"
    }
    for ($i = 0; $i -lt 20; $i++) {
        try { Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 2 | Out-Null; Ok "Yanit veriyor: $Url"; return } catch { Start-Sleep -Milliseconds 500 }
    }
    throw "Weylus $Url adresinde yanit vermiyor."
}

function Get-PhoneState($adb) {
    $lines = & $adb devices 2>$null | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
    if (-not $lines) { return $null }
    $parts = ($lines | Select-Object -First 1) -split '\s+'
    return [pscustomobject]@{ Serial = $parts[0]; State = $parts[1] }
}

function Connect-Phone($adb, [int]$TimeoutSec = 120) {
    Step 'Telefon (USB)'
    $deadline = (Get-Date).AddSeconds($TimeoutSec); $warned = $false
    while ($true) {
        $ph = Get-PhoneState $adb
        if ($ph -and $ph.State -eq 'device') { break }
        if (-not $warned) {
            if ($ph -and $ph.State -eq 'unauthorized') { Warn 'Telefonda "USB hata ayiklamaya izin ver" sorusunu onayla.' }
            else { Warn 'Telefonu USB ile bagla (USB hata ayiklama acik olmali). Bekleniyor...' }
            $warned = $true
        }
        if ((Get-Date) -gt $deadline) { throw 'Telefon bulunamadi.' }
        Start-Sleep 1
    }
    Ok "Bagli: $($ph.Serial)"

    & $adb -s $ph.Serial reverse "tcp:$Port" "tcp:$Port" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'adb reverse kurulamadi.' }
    Ok "adb reverse tcp:$Port kuruldu"

    $pkgs = & $adb -s $ph.Serial shell pm list packages --user 0 2>$null
    $browser = @('org.mozilla.firefox', 'com.android.chrome') | Where-Object { $pkgs -contains "package:$_" } | Select-Object -First 1
    $amArgs = @('shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', $Url)
    if ($browser) { $amArgs += @('-p', $browser) }
    & $adb -s $ph.Serial @amArgs | Out-Null
    Ok "Telefonda acildi: $Url $(if ($browser) { "($browser)" })"
    return $ph.Serial
}

# ---------------------------------------------------------------------------

if ($Stop) {
    Step 'Durduruluyor'
    try { $adb = Find-Adb; & $adb reverse --remove "tcp:$Port" 2>$null | Out-Null; Ok 'adb reverse kaldirildi.' } catch {}
    foreach ($p in @(Get-Process weylus -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Ok "Weylus kapatildi (PID $($p.Id))." }
        catch { Warn "Weylus (PID $($p.Id)) kapatilamadi: yonetici olarak calisiyor olabilir. Kendi penceresinden kapat." }
    }
    return
}

$adb = Find-Adb
Ensure-Driver
$display = Ensure-Display
Ensure-Weylus
$serial = Connect-Phone $adb

Write-Host ''
Write-Host "Hazir. Telefondaki sayfada ayarlari ac ve Capture bolumunden sanal ekrani ($display) sec." -ForegroundColor Green

if ($Watch) {
    Write-Host 'Kablo takip modu acik. Cikmak icin Ctrl+C.' -ForegroundColor DarkGray
    $was = $true
    while ($true) {
        Start-Sleep 2
        $ph = Get-PhoneState $adb
        $now = [bool]($ph -and $ph.State -eq 'device')
        if ($was -and -not $now) { Warn 'Telefon ayrildi, tekrar takilmasi bekleniyor...' }
        if (-not $was -and $now) {
            if (-not (Get-Process weylus -ErrorAction SilentlyContinue)) { Ensure-Weylus }
            Connect-Phone $adb | Out-Null
        }
        $was = $now
    }
}
