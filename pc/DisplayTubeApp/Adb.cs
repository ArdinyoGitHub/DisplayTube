using System.Diagnostics;
using System.IO.Compression;
using System.Text.RegularExpressions;

namespace DisplayTube.App;

/// adb islemleri. adb paketlenmiyor (Android SDK lisansi): mevcut bir adb kullanilir,
/// yoksa kullanicinin izniyle Google'in resmi platform-tools paketi indirilir.
static class Adb
{
    public const string Package = "com.displaytube.receiver";
    public const string Activity = Package + "/.MainActivity";
    const string PlatformToolsUrl = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip";

    static string LocalDir => Path.Combine(Settings.Dir, "platform-tools");

    public static string? Find()
    {
        var candidates = new List<string>
        {
            Path.Combine(LocalDir, "adb.exe"),
            Path.Combine(AppContext.BaseDirectory, "platform-tools", "adb.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk", "platform-tools", "adb.exe"),
            @"C:\platform-tools\adb.exe",
        };
        // Gelistirme ortami: proje klasorundeki tools\android-sdk
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
            candidates.Add(Path.Combine(d.FullName, "tools", "android-sdk", "platform-tools", "adb.exe"));
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            if (dir.Length > 0) candidates.Add(Path.Combine(dir.Trim(), "adb.exe"));
        return candidates.FirstOrDefault(File.Exists);
    }

    public static async Task<string> DownloadAsync()
    {
        Directory.CreateDirectory(Settings.Dir);
        string zip = Path.Combine(Settings.Dir, "platform-tools.zip");
        AppLog.Write("platform-tools indiriliyor: " + PlatformToolsUrl);
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) })
        using (var s = await http.GetStreamAsync(PlatformToolsUrl))
        using (var f = File.Create(zip))
            await s.CopyToAsync(f);
        if (Directory.Exists(LocalDir)) Directory.Delete(LocalDir, true);
        ZipFile.ExtractToDirectory(zip, Settings.Dir);   // icinde "platform-tools" klasoru var
        File.Delete(zip);
        string adb = Path.Combine(LocalDir, "adb.exe");
        if (!File.Exists(adb)) throw new Exception("adb.exe indirilen pakette yok");
        return adb;
    }

    public static (int code, string output) Run(string adb, string args, int timeoutMs = 15000)
    {
        var psi = new ProcessStartInfo(adb, args)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        using var p = Process.Start(psi)!;
        var so = p.StandardOutput.ReadToEndAsync();
        var se = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } return (-1, "zaman asimi"); }
        return (p.ExitCode, so.Result + se.Result);
    }

    /// "device", "unauthorized", "offline" ya da null (telefon yok).
    public static string? DeviceState(string adb)
    {
        var (_, o) = Run(adb, "devices");
        foreach (var line in o.Split('\n').Skip(1))
        {
            var parts = line.Trim().Split('\t', ' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2) return parts[1];
        }
        return null;
    }

    /// Telefon ekraninin yatay boyutu (uzun x kisa), orn. (2340, 1080).
    public static (int w, int h)? ScreenSize(string adb)
    {
        var (_, o) = Run(adb, "shell wm size");
        var m = Regex.Matches(o, @"(\d+)x(\d+)").LastOrDefault();   // Override size varsa o gecerli
        if (m == null) return null;
        int a = int.Parse(m.Groups[1].Value), b = int.Parse(m.Groups[2].Value);
        return (Math.Max(a, b), Math.Min(a, b));
    }

    public static int InstalledVersion(string adb)
    {
        var (_, o) = Run(adb, $"shell dumpsys package {Package}");
        var m = Regex.Match(o, @"versionCode=(\d+)");
        return m.Success ? int.Parse(m.Groups[1].Value) : 0;
    }

    public static void Install(string adb, string apk)
    {
        var (code, o) = Run(adb, $"install -r \"{apk}\"", 120_000);
        if (code != 0 || !o.Contains("Success")) throw new Exception("APK kurulamadi: " + o.Trim());
    }

    public static void Reverse(string adb, int port) => Run(adb, $"reverse tcp:{port} tcp:{port}");
    public static void RemoveReverse(string adb, int port) => Run(adb, $"reverse --remove tcp:{port}");
    public static void LaunchApp(string adb) => Run(adb, $"shell am start -n {Activity}");
}
