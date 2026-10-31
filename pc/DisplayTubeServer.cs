// DisplayTube yayin sunucusu.
//
// 127.0.0.1:<port> uzerinde TCP dinler. Bir istemci (adb reverse ile telefon)
// baglaninca ffmpeg'i baslatir, stdout'undaki FLV akisini karelere ayirip
// [tur][uzunluk][Annex-B H.264] paketleri olarak sokete yazar. Istemci kopunca
// ffmpeg'i kapatir ve yeniden bekler. ffmpeg derlemesinde tcp protokolu gerekmez.
//
// Kullanim: DisplayTubeServer.exe --ffmpeg <yol> [--port 27183] [--display auto|\\.\DISPLAYn] [--once] -- <ffmpeg argumanlari>
// ffmpeg argumanlari "-f flv pipe:1" ile bitmeli. Argumanlardaki {OUTPUT_IDX}, her
// baslangicta sanal ekranin (ya da --display ile verilen ekranin) guncel ddagrab sirasiyla degistirilir.

using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

static class DisplayTubeServer
{
    static int Main(string[] args)
    {
        int sep = Array.IndexOf(args, "--");
        if (sep < 0) { Console.Error.WriteLine("Kullanim: --ffmpeg <yol> [--port N] [--once] -- <ffmpeg argumanlari>"); return 2; }

        string ffmpeg = null, display = null, adb = null; int port = 27183; bool once = false;
        for (int i = 0; i < sep; i++)
        {
            if (args[i] == "--ffmpeg" && i + 1 < sep) ffmpeg = args[++i];
            else if (args[i] == "--port" && i + 1 < sep) port = int.Parse(args[++i]);
            else if (args[i] == "--display" && i + 1 < sep) display = args[++i];
            else if (args[i] == "--adb" && i + 1 < sep) adb = args[++i];
            else if (args[i] == "--once") once = true;
        }
        if (ffmpeg == null || !File.Exists(ffmpeg)) { Console.Error.WriteLine("ffmpeg bulunamadi: " + ffmpeg); return 2; }
        string ffArgs = string.Join(" ", args.Skip(sep + 1).Select(Quote));

        // Sadece loopback: telefona yalnizca adb reverse (USB) uzerinden ulasilir.
        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        if (adb != null) StartAdbWatch(adb, port);

        do
        {
            Log("127.0.0.1:" + port + " uzerinde istemci bekleniyor");
            using (TcpClient client = listener.AcceptTcpClient())
            {
                client.NoDelay = true;
                Log("Istemci baglandi");
                Serve(client, ffmpeg, ffArgs, display);
                Log("Istemci ayrildi");
            }
        } while (!once);

        listener.Stop();
        return 0;
    }

    // Istemci bagli kaldigi surece ffmpeg'i calistirir; ffmpeg cikar ya da takilirsa
    // (ekran kilidi, ekran duzeni degisikligi, surucu yeniden yukleme...) sebebi
    // gunluge yazar ve artan bekleme ile yeniden baslatir. Telefon baglantisi korunur.
    static void Serve(TcpClient client, string ffmpeg, string ffArgsTemplate, string display)
    {
        NetworkStream dst = client.GetStream();
        int backoffMs = 500;
        while (true)
        {
            string ffArgs = ffArgsTemplate;
            if (ffArgs.Contains("{OUTPUT_IDX}"))
            {
                string name = display == null || display == "auto" ? Displays.FindVirtualDisplay() : display;
                int idx = name == null ? -1 : Displays.DxgiOutputIndex(name);
                if (idx < 0)
                {
                    Log("Sanal ekran bulunamadi (" + (name ?? "Virtual Display Driver yok") + "), tekrar denenecek");
                    if (!WaitWhileConnected(client, backoffMs)) return;
                    backoffMs = Math.Min(backoffMs * 2, 5000);
                    continue;
                }
                Log("Ekran: " + name + " -> ddagrab output_idx " + idx);
                ffArgs = ffArgs.Replace("{OUTPUT_IDX}", idx.ToString());
            }

            long frames;
            bool clientGone = RunFfmpeg(ffmpeg, ffArgs, dst, out frames);
            if (clientGone) return;
            if (frames > 0) backoffMs = 500;   // bir sure duzgun calistiysa beklemeyi sifirla
            Log("ffmpeg durdu, " + backoffMs + " ms sonra yeniden baslatilacak");
            if (!WaitWhileConnected(client, backoffMs)) return;
            backoffMs = Math.Min(backoffMs * 2, 5000);
        }
    }

    const int StallMs = 3000;   // bu kadar sure kare gelmezse ffmpeg takilmis sayilir

    // Bir ffmpeg oturumu. Istemci koptuysa true doner.
    static bool RunFfmpeg(string ffmpeg, string ffArgs, NetworkStream dst, out long frames)
    {
        frames = 0;
        var psi = new ProcessStartInfo(ffmpeg, ffArgs)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        string lastError = null;
        long total = 0;
        bool clientGone = false;
        using (Process p = Process.Start(psi))
        {
            p.ErrorDataReceived += (s, e) =>
            {
                if (string.IsNullOrWhiteSpace(e.Data)) return;
                lastError = e.Data.Trim();
                Console.Error.WriteLine("  ffmpeg: " + lastError);
            };
            p.BeginErrorReadLine();

            // Bekci: kare akisi durursa ffmpeg'i kapat (ilk kare icin daha uzun sure tani).
            long lastPacket = Environment.TickCount;
            bool firstSeen = false;
            var watchdog = new System.Threading.Timer(_ =>
            {
                long idle = Environment.TickCount - System.Threading.Interlocked.Read(ref lastPacket);
                if (idle > (firstSeen ? StallMs : StallMs * 3) && !p.HasExited)
                {
                    lastError = "kare gelmiyor (" + idle + " ms), ekran kilitli ya da yakalama takildi";
                    try { p.Kill(); } catch { }
                }
            }, null, 1000, 1000);

            Stream src = p.StandardOutput.BaseStream;
            long n = 0;
            try
            {
                // ffmpeg FLV yazar: her kare uzunluguyla birlikte gelir, boylece kare
                // bitince hemen gonderebiliriz (Annex-B'de bir sonraki baslangic kodunu
                // beklemek bir kare gecikme eklerdi).
                ReadExact(src, new byte[13]);                    // FLV basligi + PreviousTagSize0
                var hdr = new byte[11];
                while (true)
                {
                    if (!TryReadExact(src, hdr)) break;
                    int type = hdr[0];
                    int size = (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
                    var data = new byte[size];
                    ReadExact(src, data);
                    ReadExact(src, new byte[4]);                 // PreviousTagSize

                    if (type != 9 || size < 5 || (data[0] & 0x0f) != 7) continue;   // sadece AVC video
                    bool key = (data[0] >> 4) == 1;
                    byte[] packet;
                    if (data[1] == 0) packet = Packet(PacketConfig, AvccConfigToAnnexB(data, 5));
                    else if (data[1] == 1) { packet = Packet(key ? PacketKeyFrame : PacketFrame, AvccToAnnexB(data, 5)); n++; }
                    else continue;
                    try { dst.Write(packet, 0, packet.Length); }
                    catch (IOException) { clientGone = true; break; }
                    catch (ObjectDisposedException) { clientGone = true; break; }
                    total += packet.Length;
                    System.Threading.Interlocked.Exchange(ref lastPacket, Environment.TickCount);
                    firstSeen = true;
                }
            }
            catch (IOException) { /* ffmpeg akisi bitti ya da kesildi */ }
            finally
            {
                watchdog.Dispose();
                if (!p.HasExited) { try { p.Kill(); } catch { } }
                p.WaitForExit(2000);
            }
            frames = n;
            Log(string.Format("ffmpeg oturumu bitti: {0} kare, {1:F1} MB{2}", n, total / 1048576.0,
                clientGone ? "" : ", sebep: " + (lastError ?? "kod " + (p.HasExited ? p.ExitCode.ToString() : "?"))));
        }
        return clientGone;
    }

    // Kablo cikip takilinca adb reverse kaybolur. 2 saniyede bir kontrol edip yeniden kurar.
    static void StartAdbWatch(string adb, int port)
    {
        string rule = "tcp:" + port;
        var t = new System.Threading.Thread(() =>
        {
            bool lastOk = false;
            while (true)
            {
                try
                {
                    string list = RunAdb(adb, "reverse --list");
                    bool ok = list != null && list.Contains(rule + " " + rule);
                    if (!ok)
                    {
                        string r = RunAdb(adb, "reverse " + rule + " " + rule);
                        ok = r != null && !r.Contains("error");
                        if (ok) Log("adb reverse " + rule + " kuruldu");
                        else if (lastOk) Log("Telefon ayrildi, tekrar takilmasi bekleniyor");
                    }
                    lastOk = ok;
                }
                catch (Exception e) { Log("adb kontrolu hatasi: " + e.Message); }
                System.Threading.Thread.Sleep(2000);
            }
        });
        t.IsBackground = true;
        t.Start();
    }

    static string RunAdb(string adb, string args)
    {
        var psi = new ProcessStartInfo(adb, args)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        using (var p = Process.Start(psi))
        {
            string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            if (!p.WaitForExit(5000)) { try { p.Kill(); } catch { } return null; }
            return o;
        }
    }

    // ms kadar bekler; istemci bu arada koparsa false doner.
    static bool WaitWhileConnected(TcpClient client, int ms)
    {
        int end = Environment.TickCount + ms;
        while (Environment.TickCount - end < 0)
        {
            try
            {
                if (client.Client.Poll(100 * 1000, SelectMode.SelectRead) && client.Client.Available == 0) return false;
            }
            catch (Exception) { return false; }
        }
        return true;
    }

    // Telefona giden paket: [tur:1][uzunluk:4, big-endian][Annex-B H.264]
    const byte PacketConfig = 1;     // SPS + PPS
    const byte PacketKeyFrame = 2;
    const byte PacketFrame = 3;

    static byte[] Packet(byte type, byte[] payload)
    {
        var p = new byte[5 + payload.Length];
        p[0] = type;
        p[1] = (byte)(payload.Length >> 24); p[2] = (byte)(payload.Length >> 16);
        p[3] = (byte)(payload.Length >> 8);  p[4] = (byte)payload.Length;
        Buffer.BlockCopy(payload, 0, p, 5, payload.Length);
        return p;
    }

    // AVCDecoderConfigurationRecord -> 00 00 00 01 SPS 00 00 00 01 PPS ...
    static byte[] AvccConfigToAnnexB(byte[] d, int o)
    {
        var ms = new MemoryStream();
        int pos = o + 5;
        int nSps = d[pos++] & 0x1f;
        for (int i = 0; i < nSps; i++) pos = CopyNal(d, pos, ms);
        int nPps = d[pos++];
        for (int i = 0; i < nPps; i++) pos = CopyNal(d, pos, ms);
        return ms.ToArray();
    }

    static int CopyNal(byte[] d, int pos, MemoryStream ms)
    {
        int len = (d[pos] << 8) | d[pos + 1];
        ms.Write(StartCode, 0, 4);
        ms.Write(d, pos + 2, len);
        return pos + 2 + len;
    }

    // 4 baytlik uzunluk onekli NAL'lar -> baslangic kodlu NAL'lar (ayni boyut).
    static byte[] AvccToAnnexB(byte[] d, int o)
    {
        var r = new byte[d.Length - o];
        Buffer.BlockCopy(d, o, r, 0, r.Length);
        for (int pos = 0; pos + 4 <= r.Length; )
        {
            int len = (r[pos] << 24) | (r[pos + 1] << 16) | (r[pos + 2] << 8) | r[pos + 3];
            r[pos] = 0; r[pos + 1] = 0; r[pos + 2] = 0; r[pos + 3] = 1;
            pos += 4 + len;
        }
        return r;
    }

    static readonly byte[] StartCode = { 0, 0, 0, 1 };

    static void ReadExact(Stream s, byte[] b)
    {
        if (!TryReadExact(s, b)) throw new EndOfStreamException();
    }

    static bool TryReadExact(Stream s, byte[] b)
    {
        int off = 0;
        while (off < b.Length)
        {
            int n = s.Read(b, off, b.Length - off);
            if (n <= 0) { if (off == 0) return false; throw new EndOfStreamException(); }
            off += n;
        }
        return true;
    }

    // Windows komut satiri kurallarina gore tirnakla.
    static string Quote(string a)
    {
        if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
        var sb = new StringBuilder("\"");
        int bs = 0;
        foreach (char ch in a)
        {
            if (ch == '\\') { bs++; continue; }
            if (ch == '"') { sb.Append('\\', bs * 2 + 1); sb.Append('"'); }
            else { sb.Append('\\', bs); sb.Append(ch); }
            bs = 0;
        }
        sb.Append('\\', bs * 2);
        return sb.Append('"').ToString();
    }

    static void Log(string m) { Console.Error.WriteLine("[DisplayTube " + DateTime.Now.ToString("HH:mm:ss") + "] " + m); }
}

// Sanal ekrani adiyla bulur ve ddagrab'in output_idx'ine cevirir. Ekran adi
// (\\.\DISPLAYn) ve sirasi surucu yeniden yuklenince ya da ekran duzeni degisince
// degisebildigi icin her ffmpeg baslangicinda yeniden hesaplanir.
static class Displays
{
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);

    /// Masaustune bagli "Virtual Display Driver" ekraninin adi, yoksa null.
    public static string FindVirtualDisplay()
    {
        for (uint i = 0; i < 64; i++)
        {
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            if (dd.DeviceString == "Virtual Display Driver" && (dd.StateFlags & 1) != 0) return dd.DeviceName;
        }
        return null;
    }

    // ddagrab gibi: adaptorleri ve ciktilarini sirayla gez, eslesen ekranin sirasini dondur.
    public static int DxgiOutputIndex(string deviceName)
    {
        IDXGIFactory1 factory;
        Guid iid = typeof(IDXGIFactory1).GUID;
        if (CreateDXGIFactory1(ref iid, out factory) != 0) return -1;
        try
        {
            int global = 0;
            for (uint a = 0; ; a++)
            {
                IDXGIAdapter1 adapter;
                if (factory.EnumAdapters1(a, out adapter) != 0) break;
                try
                {
                    for (uint o = 0; ; o++)
                    {
                        IDXGIOutput output;
                        if (adapter.EnumOutputs(o, out output) != 0) break;
                        try
                        {
                            DXGI_OUTPUT_DESC desc;
                            output.GetDesc(out desc);
                            if (string.Equals(desc.DeviceName, deviceName, StringComparison.OrdinalIgnoreCase)) return global;
                        }
                        finally { Marshal.ReleaseComObject(output); }
                        global++;
                    }
                }
                finally { Marshal.ReleaseComObject(adapter); }
            }
            return -1;
        }
        finally { Marshal.ReleaseComObject(factory); }
    }

    [DllImport("dxgi.dll")]
    static extern int CreateDXGIFactory1(ref Guid riid, out IDXGIFactory1 factory);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DXGI_OUTPUT_DESC
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public int Left, Top, Right, Bottom;
        public int AttachedToDesktop;
        public int Rotation;
        public IntPtr Monitor;
    }

    // Yalnizca kullanilan metotlar dogru imzali; digerleri vtable sirasi icin yer tutucu.
    [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIFactory1
    {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        void EnumAdapters(); void MakeWindowAssociation(); void GetWindowAssociation(); void CreateSwapChain(); void CreateSoftwareAdapter();
        [PreserveSig] int EnumAdapters1(uint index, out IDXGIAdapter1 adapter);
    }

    [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIAdapter1
    {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        [PreserveSig] int EnumOutputs(uint index, out IDXGIOutput output);
    }

    [ComImport, Guid("ae02eedb-c735-4690-8d52-5a8dc20213aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIOutput
    {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        void GetDesc(out DXGI_OUTPUT_DESC desc);
    }
}
