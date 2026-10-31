// DisplayTube yerel yakalama + kodlama sunucusu (ffmpeg'siz).
//
// Sanal ekrani DXGI Desktop Duplication ile yakalar, D3D11 Video Processor ile
// GPU'da BGRA -> NV12 cevirir, Windows MediaFoundation H.264 kodlayicisiyla
// (once donanim, dusuk gecikme modu; yoksa yazilim) kodlar ve DisplayTubeServer
// ile ayni paket bicimiyle 127.0.0.1:<port> uzerinden telefona yollar:
//   [tur: 1 bayt][uzunluk: 4 bayt, big-endian][Annex-B H.264]   tur 1=SPS+PPS 2=anahtar kare 3=kare
//
// Kullanim: DisplayTubeCapture.exe [--port 27183] [--display auto|\\.\DISPLAYn] [--fps 60]
//                                  [--bitrate 12000000] [--software] [--adb <adb.exe>] [--launch-app <paket/.Aktivite>]
//                                  [--once] [--selftest]
// stdout: makinece okunur durum satirlari ("#client 1", "#encoder ...", "#fps 59.9", "#size 1920x1080"),
// stderr: insan icin gunluk.

using System.Diagnostics;
using System.Net;
using System.Net.Sockets;

namespace DisplayTube;

static class Program
{
    // DisplayTube.exe (bildirim alani uygulamasi) bunu "--engine ..." ile de cagirir.
    internal static int Main(string[] args)
    {
        var opt = Options.Parse(args);
        if (opt == null) return 2;
        if (opt.SelfTest) return SelfTest(opt);

        var listener = new TcpListener(IPAddress.Loopback, opt.Port);   // yalnizca USB (adb reverse)
        listener.Start();
        if (opt.Adb != null) AdbWatch.Start(opt.Adb, opt.Port, opt.LaunchApp);
        Status.Emit("listening", opt.Port.ToString());

        do
        {
            Log.Info($"127.0.0.1:{opt.Port} uzerinde istemci bekleniyor");
            using var client = listener.AcceptTcpClient();
            client.NoDelay = true;
            Log.Info("Istemci baglandi");
            Status.Emit("client", "1");
            Serve(client, opt);
            Log.Info("Istemci ayrildi");
            Status.Emit("client", "0");
        } while (!opt.Once);
        return 0;
    }

    // Istemci bagli kaldigi surece yakalama oturumunu calistirir; oturum duserse
    // (ekran kilidi, ekran duzeni degisikligi, surucu yeniden yukleme) telefonu
    // koparmadan artan beklemeyle yeniden kurar.
    static void Serve(TcpClient client, Options opt)
    {
        var sink = new PacketSink(client.GetStream());
        int backoff = 500;
        while (true)
        {
            long frames = 0;
            try
            {
                using var session = new CaptureSession(opt, sink);
                frames = session.Run();
            }
            catch (ClientGoneException) { return; }
            catch (Exception e)
            {
                Log.Info("Oturum hatasi: " + e.Message);
            }
            if (sink.Gone || !WaitWhileConnected(client, backoff)) return;
            backoff = frames > 0 ? 500 : Math.Min(backoff * 2, 5000);
        }
    }

    // Istemci olmadan birkac kare yakalayip kodlar: bu sistemde yerel yol calisiyor mu?
    // stream.ps1 buna gore yerel programi ya da ffmpeg yolunu secer.
    static int SelfTest(Options opt)
    {
        try
        {
            var sink = new PacketSink(Stream.Null);
            using var session = new CaptureSession(opt, sink);
            long n = session.Run(5);
            Console.WriteLine($"OK {session.Width}x{session.Height} {session.EncoderName} ({n} kare)");
            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine("HATA " + e.Message);
            return 1;
        }
    }

    static bool WaitWhileConnected(TcpClient client, int ms)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < ms)
        {
            try
            {
                if (client.Client.Poll(100_000, SelectMode.SelectRead) && client.Client.Available == 0) return false;
            }
            catch { return false; }
        }
        return true;
    }
}

sealed class Options
{
    public int Port = 27183;
    public string Display = "auto";
    public int Fps = 60;
    public int Bitrate = 12_000_000;
    public bool Software;
    public string? Adb;
    public bool Once;
    public bool SelfTest;
    public string? LaunchApp;   // kablo takilinca telefonda acilacak uygulama, orn. com.displaytube.receiver/.MainActivity

    public static Options? Parse(string[] a)
    {
        var o = new Options();
        for (int i = 0; i < a.Length; i++)
        {
            string Next() => i + 1 < a.Length ? a[++i] : throw new ArgumentException("eksik deger: " + a[i]);
            switch (a[i])
            {
                case "--port": o.Port = int.Parse(Next()); break;
                case "--display": o.Display = Next(); break;
                case "--fps": o.Fps = int.Parse(Next()); break;
                case "--bitrate": o.Bitrate = int.Parse(Next()); break;
                case "--software": o.Software = true; break;
                case "--adb": o.Adb = Next(); break;
                case "--once": o.Once = true; break;
                case "--selftest": o.SelfTest = true; break;
                case "--launch-app": o.LaunchApp = Next(); break;
                default: Console.Error.WriteLine("Bilinmeyen arguman: " + a[i]); return null;
            }
        }
        return o;
    }
}

sealed class ClientGoneException : Exception { }

/// Telefona giden paketleri yazar. Istemci koparsa ClientGoneException atar.
sealed class PacketSink(Stream stream)
{
    public const byte Config = 1, KeyFrame = 2, Frame = 3;
    public bool Gone { get; private set; }
    readonly byte[] header = new byte[5];

    public void Send(byte type, ReadOnlySpan<byte> payload)
    {
        header[0] = type;
        header[1] = (byte)(payload.Length >> 24); header[2] = (byte)(payload.Length >> 16);
        header[3] = (byte)(payload.Length >> 8);  header[4] = (byte)payload.Length;
        try
        {
            stream.Write(header);
            stream.Write(payload);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException)
        {
            Gone = true;
            throw new ClientGoneException();
        }
    }
}

static class Log
{
    public static void Info(string m) => Console.Error.WriteLine($"[DisplayTube {DateTime.Now:HH:mm:ss}] {m}");
}

/// Bildirim alani uygulamasi icin durum satirlari (stdout).
static class Status
{
    public static void Emit(string key, string value)
    {
        lock (typeof(Status)) { Console.Out.WriteLine("#" + key + " " + value); Console.Out.Flush(); }
    }
}

/// Kablo cikip takilinca adb reverse kaybolur; 2 saniyede bir kontrol edip yeniden kurar.
static class AdbWatch
{
    public static void Start(string adb, int port, string? launchApp)
    {
        string rule = "tcp:" + port;
        var t = new Thread(() =>
        {
            bool lastOk = false;
            while (true)
            {
                try
                {
                    string? list = Run(adb, "reverse --list");
                    bool ok = list != null && list.Contains(rule + " " + rule);
                    if (!ok)
                    {
                        string? r = Run(adb, $"reverse {rule} {rule}");
                        ok = r != null && !r.Contains("error");
                        if (ok)
                        {
                            Log.Info("adb reverse " + rule + " kuruldu");
                            // Kablo yeniden takildi: telefondaki uygulamayi da ac.
                            if (launchApp != null && lastOk == false) Run(adb, "shell am start -n " + launchApp);
                        }
                        else if (lastOk) Log.Info("Telefon ayrildi, tekrar takilmasi bekleniyor");
                    }
                    if (ok != lastOk) Status.Emit("phone", ok ? "1" : "0");
                    lastOk = ok;
                }
                catch (Exception e) { Log.Info("adb kontrolu hatasi: " + e.Message); }
                Thread.Sleep(2000);
            }
        }) { IsBackground = true };
        t.Start();
    }

    static string? Run(string exe, string args)
    {
        var psi = new ProcessStartInfo(exe, args)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        using var p = Process.Start(psi)!;
        string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
        if (!p.WaitForExit(5000)) { try { p.Kill(); } catch { } return null; }
        return o;
    }
}
