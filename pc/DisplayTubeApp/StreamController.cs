using System.Diagnostics;
using System.Globalization;

namespace DisplayTube.App;

enum Phase { Stopped, Preparing, WaitingForPhone, Streaming, Error }

sealed class StreamStatus
{
    public Phase Phase = Phase.Stopped;
    public bool PhoneConnected, ClientConnected;
    public string? Encoder, Size, Message;
    public double Fps;
}

/// Yayin akisinin tamami: adb, surucu, telefon (APK kurulumu, cozunurluk, adb reverse,
/// uygulamayi acma) ve yakalama motoru (DisplayTubeCapture; calismazsa ffmpeg yolu).
sealed class StreamController
{
    public const int Port = 27183;
    const int ApkVersion = 3;   // android/AndroidManifest.xml versionCode ile ayni olmali

    readonly Settings settings;
    readonly Func<string, string, bool> confirm;   // (baslik, metin) -> kullanici onayi (UI thread'de)
    public readonly StreamStatus Status = new();
    public event Action? Changed;

    volatile bool running;
    Thread? worker;
    Process? engine;
    string? adb;

    public StreamController(Settings settings, Func<string, string, bool> confirm)
    {
        this.settings = settings;
        this.confirm = confirm;
    }

    public bool IsRunning => running;

    public void Start()
    {
        if (running) return;
        running = true;
        worker = new Thread(Work) { IsBackground = true, Name = "DisplayTube" };
        worker.Start();
    }

    public void Stop()
    {
        running = false;
        StopEngine();
        if (adb != null) try { Adb.RemoveReverse(adb, Port); } catch { }
        worker?.Join(3000);
        VirtualDisplay.Detach();
        Set(s => { s.Phase = Phase.Stopped; s.ClientConnected = false; s.Fps = 0; s.Message = null; });
    }

    /// Cozunurluk ayari degisince telefon yeniden hazirlanir.
    public void ResolutionChanged() => phoneReady = false;

    void Set(Action<StreamStatus> f)
    {
        lock (Status) f(Status);
        Changed?.Invoke();
    }

    void Fail(string message)
    {
        AppLog.Write("HATA: " + message);
        Set(s => { s.Phase = Phase.Error; s.Message = message; });
        running = false;
        StopEngine();
        VirtualDisplay.Detach();
    }

    bool phoneReady;

    void Work()
    {
        try
        {
            Set(s => { s.Phase = Phase.Preparing; s.Message = T.S("Hazirlaniyor...", "Preparing..."); });

            // 1) adb
            adb = Adb.Find();
            if (adb == null)
            {
                if (!settings.AdbDownloadAllowed)
                {
                    if (!confirm(T.S("Android araclari gerekli", "Android tools required"),
                        T.S("Telefonla USB uzerinden konusmak icin Google'in resmi Android platform-tools paketi (adb, ~15 MB) gerekiyor.\n\n" +
                            "Simdi dl.google.com adresinden indirilsin mi?",
                            "Talking to the phone over USB needs Google's official Android platform-tools (adb, ~15 MB).\n\n" +
                            "Download it now from dl.google.com?")))
                    { Fail(T.S("adb olmadan telefona baglanilamaz", "Cannot reach the phone without adb")); return; }
                    settings.AdbDownloadAllowed = true;
                    settings.Save();
                }
                Set(s => s.Message = T.S("Android araclari indiriliyor...", "Downloading Android tools..."));
                adb = Adb.DownloadAsync().GetAwaiter().GetResult();
            }
            AppLog.Write("adb: " + adb);

            // 2) Sanal ekran surucusu
            if (!VirtualDisplay.IsInstalled())
            {
                if (!confirm(T.S("Sanal ekran surucusu", "Virtual display driver"),
                    T.S("Telefonun ikinci ekran olabilmesi icin acik kaynakli Virtual Display Driver kurulacak.\n" +
                        "Yonetici izni (UAC) istenecek ve surucunun imza sertifikasi guvenilir listeye eklenecek.\n\nDevam edilsin mi?",
                        "The open-source Virtual Display Driver will be installed so the phone can act as a second screen.\n" +
                        "Administrator permission (UAC) will be requested and the driver's signing certificate will be trusted.\n\nContinue?")))
                { Fail(T.S("Surucu kurulmadi", "Driver not installed")); return; }
                Set(s => s.Message = T.S("Surucu kuruluyor...", "Installing driver..."));
                if (!VirtualDisplay.InstallElevated() || !VirtualDisplay.IsInstalled())
                { Fail(T.S("Surucu kurulamadi (gunluge bakin)", "Driver installation failed (see log)")); return; }
            }
            VirtualDisplay.EnsureAttached();

            // 3) Motor
            if (!StartEngine()) return;

            // 4) Telefon izleme dongusu
            Set(s => { s.Phase = Phase.WaitingForPhone; s.Message = T.S("Telefon bekleniyor (USB)", "Waiting for phone (USB)"); });
            string? lastState = null;
            phoneReady = false;
            while (running)
            {
                string? state = Adb.DeviceState(adb);
                if (state != lastState)
                {
                    AppLog.Write("Telefon durumu: " + (state ?? "yok"));
                    lastState = state;
                    if (state != "device") phoneReady = false;
                    Set(s =>
                    {
                        s.PhoneConnected = state == "device";
                        if (state == "unauthorized") s.Message = T.S("Telefonda 'USB hata ayiklamaya izin ver' sorusunu onaylayin", "Allow USB debugging on the phone");
                        else if (state == null) s.Message = T.S("Telefon bekleniyor (USB)", "Waiting for phone (USB)");
                    });
                }
                if (state == "device" && !phoneReady)
                {
                    PreparePhone();
                    phoneReady = true;
                }
                if (engine != null && engine.HasExited && running)
                {
                    AppLog.Write("Motor durdu, yeniden baslatiliyor");
                    Thread.Sleep(1000);
                    if (!StartEngine()) return;
                }
                Thread.Sleep(2000);
            }
        }
        catch (Exception e) { Fail(e.Message); }
    }

    void PreparePhone()
    {
        Set(s => s.Message = T.S("Telefon hazirlaniyor...", "Preparing phone..."));
        string? apk = FindFile("DisplayTube.apk", Path.Combine("android", "build", "DisplayTube.apk"));
        int installed = Adb.InstalledVersion(adb!);
        if (apk != null && installed < ApkVersion)
        {
            Set(s => s.Message = T.S("Telefona uygulama kuruluyor...", "Installing app on phone..."));
            AppLog.Write($"APK kuruluyor (telefondaki surum {installed}, yeni {ApkVersion})");
            Adb.Install(adb!, apk);
        }
        else if (apk == null && installed == 0)
            AppLog.Write("UYARI: DisplayTube.apk bulunamadi ve telefonda uygulama yok");

        // Cozunurluk
        try
        {
            if (settings.Resolution == "phone")
            {
                var size = Adb.ScreenSize(adb!);
                if (size is var (pw, ph))
                {
                    var (w, h) = VirtualDisplay.PhoneMode(pw, ph);
                    VirtualDisplay.Apply(w, h, settings.Fps);
                }
            }
            else if (settings.Resolution != "keep" && TryParseSize(settings.Resolution, out int fw, out int fh))
                VirtualDisplay.Apply(fw, fh, settings.Fps);
        }
        catch (Exception e) { AppLog.Write("Cozunurluk ayarlanamadi: " + e.Message); }

        Adb.Reverse(adb!, Port);
        Adb.LaunchApp(adb!);
        Set(s => s.Message = null);
    }

    static bool TryParseSize(string s, out int w, out int h)
    {
        w = h = 0;
        var p = s.Split('x');
        return p.Length == 2 && int.TryParse(p[0], out w) && int.TryParse(p[1], out h);
    }

    // ---- Motor ----

    bool StartEngine()
    {
        StopEngine();
        // Motor bu exe'nin icinde ("--engine" modu).
        string? exe = Environment.ProcessPath;
        if (exe != null)
        {
            var (ok, msg) = RunSelfTest(exe);
            AppLog.Write("Motor oz testi: " + msg);
            if (ok)
            {
                engine = Launch(exe, string.Join(" ", "--engine",
                    "--port", Port, "--display", "auto", "--fps", settings.Fps, "--bitrate", settings.Bitrate,
                    "--adb", Quote(adb!), "--launch-app", Adb.Activity));
                return true;
            }
        }
        // Yedek: ffmpeg yolu (yalnizca gelistirme klasorunde, ffmpeg varsa)
        string? script = FindFile(Path.Combine("pc", "stream.ps1"));
        if (script != null)
        {
            AppLog.Write("Yerel motor calismadi, ffmpeg yolu deneniyor");
            engine = Launch("powershell", $"-NoProfile -ExecutionPolicy Bypass -File {Quote(script)} -Engine ffmpeg -Port {Port}");
            return true;
        }
        Fail(T.S("Goruntu yakalama bu sistemde baslatilamadi (gunluge bakin)", "Screen capture could not start on this system (see log)"));
        return false;
    }

    static (bool ok, string msg) RunSelfTest(string exe)
    {
        var psi = new ProcessStartInfo(exe, "--engine --selftest")
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        using var p = Process.Start(psi)!;
        var err = p.StandardError.ReadToEndAsync();
        string o = p.StandardOutput.ReadToEnd().Trim();
        if (!p.WaitForExit(20000)) { try { p.Kill(true); } catch { } return (false, "zaman asimi"); }
        AppLog.Write(err.Result.Trim());
        return (p.ExitCode == 0, o);
    }

    Process Launch(string exe, string args)
    {
        AppLog.Write($"Baslatiliyor: {exe} {args}");
        var psi = new ProcessStartInfo(exe, args)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) OnEngineLine(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) AppLog.Write("motor: " + e.Data); };
        p.Start();
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        return p;
    }

    void OnEngineLine(string line)
    {
        if (!line.StartsWith('#')) return;
        int sp = line.IndexOf(' ');
        string key = sp > 0 ? line[1..sp] : line[1..], val = sp > 0 ? line[(sp + 1)..] : "";
        Set(s =>
        {
            switch (key)
            {
                case "client":
                    s.ClientConnected = val == "1";
                    s.Phase = s.ClientConnected ? Phase.Streaming : Phase.WaitingForPhone;
                    if (!s.ClientConnected) s.Fps = 0;
                    break;
                case "encoder": s.Encoder = val; break;
                case "size": s.Size = val; break;
                case "fps": s.Fps = double.Parse(val, CultureInfo.InvariantCulture); break;
            }
        });
    }

    void StopEngine()
    {
        var p = engine;
        engine = null;
        if (p == null) return;
        try { if (!p.HasExited) p.Kill(true); } catch { }
        p.Dispose();
    }

    static string Quote(string s) => "\"" + s + "\"";

    /// Surum zip'inde exe'nin yanindaki dosya; gelistirmede proje klasorundeki karsiligi.
    static string? FindFile(params string[] relative)
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
            foreach (var r in relative)
            {
                string p = Path.Combine(d.FullName, r);
                if (File.Exists(p)) return p;
            }
        return null;
    }
}
