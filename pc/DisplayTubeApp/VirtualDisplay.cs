using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml.Linq;

namespace DisplayTube.App;

/// Virtual Display Driver (MttVDD): kurulum kontrolu, kurulum (yonetici), ekran
/// cozunurlugu. Surucu ayarlari C:\VirtualDisplayDriver\vdd_settings.xml'de.
static class VirtualDisplay
{
    public const string SettingsDir = @"C:\VirtualDisplayDriver";
    static string SettingsFile => Path.Combine(SettingsDir, "vdd_settings.xml");
    const string AdapterName = "Virtual Display Driver";

    /// Surucu paketinin bulundugu klasor (surum zip'inde "driver", gelistirmede "VirtualDisplayDriver").
    public static string? DriverDir()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
            foreach (var name in new[] { "driver", "VirtualDisplayDriver" })
            {
                string p = Path.Combine(d.FullName, name);
                if (File.Exists(Path.Combine(p, "MttVDD.inf"))) return p;
            }
        return null;
    }

    /// Surucu cihazi kurulu ve calisiyor mu.
    public static bool IsInstalled()
    {
        var psi = new ProcessStartInfo("pnputil", "/enum-devices /class Display")
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        using var p = Process.Start(psi)!;
        string o = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        return o.Contains(AdapterName, StringComparison.OrdinalIgnoreCase) || FindDisplay() != null;
    }

    /// Kurulumu yonetici olarak bu programin "--install-driver" moduyla yapar (UAC sorulur).
    public static bool InstallElevated()
    {
        string? dir = DriverDir() ?? throw new Exception(T.S("Surucu dosyalari bulunamadi", "Driver files not found"));
        var psi = new ProcessStartInfo(Environment.ProcessPath!, $"--install-driver \"{dir}\"")
        { UseShellExecute = true, Verb = "runas" };
        try
        {
            using var p = Process.Start(psi)!;
            p.WaitForExit();
            return p.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception) { return false; }   // kullanici UAC'yi reddetti
    }

    /// Yonetici modunda calisir: sertifika, ayar dosyasi, surucu paketi, kok cihaz.
    public static int InstallAsAdmin(string dir)
    {
        try
        {
            // VDD kendinden imzali; Windows'un surucuyu yuklemesi icin sertifikasi guvenilir olmali.
            string cer = Path.Combine(dir, "Virtual_Display_Driver.cer");
            if (File.Exists(cer))
            {
                RunQuiet("certutil", $"-addstore -f root \"{cer}\"");
                RunQuiet("certutil", $"-addstore -f TrustedPublisher \"{cer}\"");
            }
            Directory.CreateDirectory(SettingsDir);
            if (!File.Exists(SettingsFile)) File.Copy(Path.Combine(dir, "vdd_settings.xml"), SettingsFile);
            string inf = Path.Combine(dir, "MttVDD.inf");
            RunQuiet("pnputil", $"/add-driver \"{inf}\"");
            string r = RootDevice.Install(inf, @"Root\MttVDD");
            AppLog.Write("Surucu kurulumu: " + r);
            return r.StartsWith("OK") ? 0 : 1;
        }
        catch (Exception e) { AppLog.Write("Surucu kurulumu hatasi: " + e); return 1; }
    }

    static void RunQuiet(string exe, string args)
    {
        var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        using var p = Process.Start(psi)!;
        AppLog.Write($"{exe} {args}: " + p.StandardOutput.ReadToEnd().Trim().Replace(Environment.NewLine, " | "));
        p.WaitForExit();
    }

    // ---- Ekran ----

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string? dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string? dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string? dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr lParam);

    /// Sanal ekranin adi (\\.\DISPLAYn) ve masaustune bagli olup olmadigi.
    public static (string name, bool attached)? FindDisplay()
    {
        for (uint i = 0; i < 64; i++)
        {
            var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            if (dd.DeviceString == AdapterName) return (dd.DeviceName, (dd.StateFlags & 1) != 0);
        }
        return null;
    }

    public static (int w, int h)? CurrentSize(string name)
    {
        var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
        return EnumDisplaySettings(name, -1, ref dm) ? (dm.dmPelsWidth, dm.dmPelsHeight) : null;
    }

    static bool HasMode(string name, int w, int h)
    {
        var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
        for (int i = 0; EnumDisplaySettings(name, i, ref dm); i++)
            if (dm.dmPelsWidth == w && dm.dmPelsHeight == h) return true;
        return false;
    }

    /// Telefon ekranina gore guvenli bir boyut: en fazla 1080 yukseklik, cift sayilar.
    public static (int w, int h) PhoneMode(int phoneW, int phoneH)
    {
        int h = Math.Min(phoneH, 1080) & ~1;
        int w = (int)Math.Round(phoneW * (double)h / phoneH) & ~1;
        return (w, h);
    }

    /// Sanal ekrani masaustune bagli ve istenen boyutta yapar. Boyut surucunun
    /// listesinde yoksa ayar dosyasina ekleyip surucuyu yeniden yukletir (UAC gerekmez).
    public static void Apply(int w, int h, int fps)
    {
        var d = WaitForDisplay(TimeSpan.FromSeconds(10)) ?? throw new Exception(T.S("Sanal ekran bulunamadi", "Virtual display not found"));
        if (!HasMode(d.name, w, h))
        {
            AddModeToSettings(w, h, fps);
            ReloadDriver();
            Thread.Sleep(2000);
            d = WaitForDisplay(TimeSpan.FromSeconds(15)) ?? throw new Exception(T.S("Surucu yeniden yuklenemedi", "Driver reload failed"));
            for (int i = 0; i < 20 && !HasMode(d.name, w, h); i++) { Thread.Sleep(500); d = FindDisplay() ?? d; }
            if (!HasMode(d.name, w, h)) throw new Exception($"{w}x{h} " + T.S("eklenemedi", "could not be added"));
        }
        var cur = CurrentSize(d.name);
        if (d.attached && cur == (w, h)) return;

        var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
        EnumDisplaySettings(d.name, -1, ref dm);
        dm.dmPelsWidth = w; dm.dmPelsHeight = h;
        dm.dmFields = 0x80000 | 0x100000;                         // DM_PELSWIDTH | DM_PELSHEIGHT
        if (!d.attached)
        {
            // Genislet: diger ekranlarin sagina yerlestir.
            dm.dmPositionX = Screen.AllScreens.Max(s => s.Bounds.Right);
            dm.dmPositionY = 0;
            dm.dmFields |= 0x20;                                  // DM_POSITION
        }
        int r = ChangeDisplaySettingsEx(d.name, ref dm, IntPtr.Zero, 0x1 | 0x10000000, IntPtr.Zero);   // UPDATEREGISTRY | NORESET
        if (r != 0) throw new Exception($"ChangeDisplaySettingsEx: {r}");
        ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        AppLog.Write($"Sanal ekran {w}x{h} yapildi ({d.name})");
    }

    /// Sanal ekran yalnizca masaustune bagli degilse baglar (boyutu degistirmez).
    public static void EnsureAttached()
    {
        var d = WaitForDisplay(TimeSpan.FromSeconds(10)) ?? throw new Exception(T.S("Sanal ekran bulunamadi", "Virtual display not found"));
        if (d.attached) return;
        var cur = CurrentSize(d.name) ?? (1920, 1080);
        Apply(cur.w, cur.h, 60);
    }

    /// Sanal ekrani masaustunden ayirir (surucu yuklu kalir, ekran Windows'ta gorunmez olur).
    /// DisplayTube durunca ya da kapaninca cagrilir; yoksa bos bir ikinci ekran acik kalir.
    /// EnsureAttached/Apply sonraki baslatmada ekrani yeniden baglar.
    public static void Detach()
    {
        try
        {
            var d = FindDisplay();
            if (d == null || !d.Value.attached) return;
            var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
            EnumDisplaySettings(d.Value.name, -1, ref dm);
            dm.dmPelsWidth = 0; dm.dmPelsHeight = 0; dm.dmPositionX = 0; dm.dmPositionY = 0;
            dm.dmFields = 0x20 | 0x80000 | 0x100000;              // DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT
            int r = ChangeDisplaySettingsEx(d.Value.name, ref dm, IntPtr.Zero, 0x1 | 0x10000000, IntPtr.Zero);   // UPDATEREGISTRY | NORESET
            if (r != 0) { AppLog.Write($"Sanal ekran ayrilamadi: ChangeDisplaySettingsEx {r}"); return; }
            ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
            AppLog.Write($"Sanal ekran masaustunden ayrildi ({d.Value.name})");
        }
        catch (Exception e) { AppLog.Write("Sanal ekran ayrilamadi: " + e.Message); }
    }

    static (string name, bool attached)? WaitForDisplay(TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        while (true)
        {
            var d = FindDisplay();
            if (d != null || sw.Elapsed > timeout) return d;
            Thread.Sleep(300);
        }
    }

    static void AddModeToSettings(int w, int h, int fps)
    {
        var doc = XDocument.Load(SettingsFile);
        var res = doc.Root!.Element("resolutions")!;
        if (res.Elements("resolution").Any(r => (int?)r.Element("width") == w && (int?)r.Element("height") == h)) return;
        res.Add(new XElement("resolution",
            new XElement("width", w), new XElement("height", h),
            new XElement("refresh_rate", 60), fps != 60 ? new XElement("refresh_rate", fps) : null));
        doc.Save(SettingsFile);
        AppLog.Write($"Surucu ayarina {w}x{h} eklendi");
    }

    /// Surucunun kendi denetim kanaliyla ayarlari yeniden okutur (yonetici gerekmez).
    static void ReloadDriver()
    {
        using var pipe = new NamedPipeClientStream(".", "MTTVirtualDisplayPipe", PipeDirection.InOut);
        pipe.Connect(3000);
        var b = Encoding.Unicode.GetBytes("RELOAD_DRIVER");
        pipe.Write(b, 0, b.Length);
        pipe.Flush();
    }
}

/// devcon'un yaptigi gibi kok (Root\...) cihaz olusturup surucuyu kurar.
static class RootDevice
{
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }

    [DllImport("setupapi.dll", SetLastError = true)] static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid cls, IntPtr hwnd);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid cls, string? desc, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data, int prop, byte[] buf, int size);
    [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiCallClassInstaller(int dif, IntPtr set, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true)] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hwid, string inf, int flags, out bool reboot);

    public static string Install(string inf, string hwid)
    {
        if (VirtualDisplay.FindDisplay() != null) return "OK (zaten var)";
        var cls = new Guid("4D36E968-E325-11CE-BFC1-08002BE10318");   // Display sinifi
        IntPtr set = SetupDiCreateDeviceInfoList(ref cls, IntPtr.Zero);
        try
        {
            var d = new SP_DEVINFO_DATA { cbSize = Marshal.SizeOf<SP_DEVINFO_DATA>() };
            if (!SetupDiCreateDeviceInfo(set, "Display", ref cls, null, IntPtr.Zero, 1, ref d))
                return "CreateDeviceInfo " + Marshal.GetLastWin32Error();
            var ids = Encoding.Unicode.GetBytes(hwid + "\0\0");
            if (!SetupDiSetDeviceRegistryProperty(set, ref d, 1, ids, ids.Length))   // SPDRP_HARDWAREID
                return "SetHardwareId " + Marshal.GetLastWin32Error();
            if (!SetupDiCallClassInstaller(0x19, set, ref d))                       // DIF_REGISTERDEVICE
                return "RegisterDevice " + Marshal.GetLastWin32Error();
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, inf, 1, out bool reboot))   // INSTALLFLAG_FORCE
            return "UpdateDriver " + Marshal.GetLastWin32Error();
        return "OK" + (reboot ? " (yeniden baslatma gerekli)" : "");
    }
}
