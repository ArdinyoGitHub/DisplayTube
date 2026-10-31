using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;

namespace DisplayTube;

/// Bir yakalama + kodlama oturumu. Ekran kaybolursa (ACCESS_LOST vb.) Run istisna
/// firlatir; Program onu yeniden kurar.
sealed class CaptureSession : IDisposable
{
    const int RingSize = 6;   // kodlayici eski kareleri okurken uzerine yazmamak icin NV12 halkasi

    readonly Options opt;
    readonly PacketSink sink;
    readonly ID3D11Device device;
    readonly ID3D11DeviceContext context;
    readonly ID3D11VideoDevice videoDevice;
    readonly ID3D11VideoContext videoContext;
    readonly IDXGIOutputDuplication dup;
    readonly ID3D11Texture2D work;             // BGRA kopya (imlec bunun uzerine cizilir)
    readonly ID3D11VideoProcessorEnumerator vpEnum;
    readonly ID3D11VideoProcessor vp;
    readonly ID3D11VideoProcessorInputView vpIn;
    readonly ID3D11Texture2D[] nv12 = new ID3D11Texture2D[RingSize];
    readonly ID3D11VideoProcessorOutputView[] vpOut = new ID3D11VideoProcessorOutputView[RingSize];
    readonly Cursor cursor;
    readonly IVideoEncoder encoder;
    public readonly int Width, Height;
    public string EncoderName => encoder.Name;

    public CaptureSession(Options opt, PacketSink sink)
    {
        this.opt = opt;
        this.sink = sink;

        string name = opt.Display == "auto" ? Displays.FindVirtualDisplay() ?? throw new Exception("Sanal ekran (Virtual Display Driver) bulunamadi")
                                            : opt.Display;
        var (adapter, output) = Displays.FindOutput(name) ?? throw new Exception(name + " icin DXGI ciktisi bulunamadi");
        using (adapter)
        using (output)
        {
            var ad = adapter.Description1;
            Log.Info($"Ekran: {name}, ekran karti: {ad.Description}");

            D3D11.D3D11CreateDevice(adapter, DriverType.Unknown,
                DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
                new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0 }, out device!, out context!).CheckError();
            using (var mt = device.QueryInterface<ID3D11Multithread>()) mt.SetMultithreadProtected(true);
            videoDevice = device.QueryInterface<ID3D11VideoDevice>();
            videoContext = context.QueryInterface<ID3D11VideoContext>();

            using var output1 = output.QueryInterface<IDXGIOutput1>();
            dup = output1.DuplicateOutput(device);
            var dd = dup.Description;
            Width = (int)dd.ModeDescription.Width & ~1;
            Height = (int)dd.ModeDescription.Height & ~1;
            Log.Info($"Yakalama: {Width}x{Height}, {opt.Fps} FPS");

            work = device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)Width, Height = (uint)Height, MipLevels = 1, ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default, BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource
            });

            vpEnum = videoDevice.CreateVideoProcessorEnumerator(new VideoProcessorContentDescription
            {
                InputFrameFormat = VideoFrameFormat.Progressive,
                InputFrameRate = new Rational((uint)opt.Fps, 1), InputWidth = (uint)Width, InputHeight = (uint)Height,
                OutputFrameRate = new Rational((uint)opt.Fps, 1), OutputWidth = (uint)Width, OutputHeight = (uint)Height,
                Usage = VideoUsage.OptimalSpeed
            });
            vp = videoDevice.CreateVideoProcessor(vpEnum, 0);
            vpIn = videoDevice.CreateVideoProcessorInputView(work, vpEnum, new VideoProcessorInputViewDescription
            {
                FourCC = 0, ViewDimension = VideoProcessorInputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 }
            });
            for (int i = 0; i < RingSize; i++)
            {
                nv12[i] = device.CreateTexture2D(new Texture2DDescription
                {
                    Width = (uint)Width, Height = (uint)Height, MipLevels = 1, ArraySize = 1,
                    Format = Format.NV12, SampleDescription = new SampleDescription(1, 0),
                    Usage = ResourceUsage.Default, BindFlags = BindFlags.RenderTarget
                });
                vpOut[i] = videoDevice.CreateVideoProcessorOutputView(nv12[i], vpEnum, new VideoProcessorOutputViewDescription
                {
                    ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                    Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 }
                });
            }
            videoContext.VideoProcessorSetStreamFrameFormat(vp, 0, VideoFrameFormat.Progressive);
            videoContext.VideoProcessorSetStreamAutoProcessingMode(vp, 0, false);   // ek filtre yok, sadece donusum

            cursor = new Cursor(device, context, work, Width, Height);
            encoder = EncoderFactory.Create(device, context, ad.Luid, Width, Height, opt);
            Log.Info("Kodlayici: " + encoder.Name);
            Status.Emit("encoder", encoder.Name);
            Status.Emit("size", $"{Width}x{Height}");
        }
    }

    /// Ekran kaybolana ya da istemci kopana kadar calisir; gonderilen kare sayisini dondurur.
    public long Run(long maxFrames = long.MaxValue)
    {
        long frames = 0, captured = 0;
        int ring = 0;
        var clock = Stopwatch.StartNew();
        long frameTicks = 10_000_000L / opt.Fps;
        var stats = Stopwatch.StartNew();
        bool haveFrame = false;
        var fpsMark = Stopwatch.StartNew();
        long fpsFrames = 0;

        while (true)
        {
            // Yeni kare yoksa (ekran durgun) de periyodik olarak son kareyi tekrar kodlariz;
            // boylece baglanan istemci hemen goruntu alir ve kodlayici akisi canli kalir.
            var r = dup.AcquireNextFrame((uint)Math.Max(1, 1000 / opt.Fps), out var info, out var res);
            if (r.Success)
            {
                using (res)
                using (var tex = res.QueryInterface<ID3D11Texture2D>())
                {
                    if (info.LastPresentTime != 0)
                        context.CopySubresourceRegion(work, 0, 0, 0, 0, tex, 0, new Box(0, 0, 0, Width, Height, 1));
                }
                cursor.Update(dup, info);
                dup.ReleaseFrame();
                if (info.LastPresentTime == 0 && info.LastMouseUpdateTime == 0 && haveFrame) continue;
                haveFrame = true;
                captured++;
            }
            else if (r.Code == Vortice.DXGI.ResultCode.WaitTimeout.Code)
            {
                if (!haveFrame) continue;
                // Durgun ekran: ~4 FPS ile tekrar gonder (canli tutma)
                if (clock.ElapsedTicks * 10_000_000L / Stopwatch.Frequency < frames * frameTicks + 2_500_000) continue;
            }
            else
            {
                throw new Exception($"AcquireNextFrame basarisiz: 0x{r.Code:X8} (ekran kilidi ya da ekran degisikligi)");
            }

            cursor.DrawInto();   // imleci BGRA kopyaya ciz (kucuk bolge, CPU'da)

            int slot = ring; ring = (ring + 1) % RingSize;
            videoContext.VideoProcessorBlt(vp, vpOut[slot], 0, 1, new[] { new VideoProcessorStream { Enable = true, InputSurface = vpIn } });
            cursor.EraseFrom();   // bir sonraki karede imlecin altindaki goruntu dogru kalsin

            long pts = clock.ElapsedTicks * 10_000_000L / Stopwatch.Frequency;
            encoder.Encode(nv12[slot], pts, sink);
            frames++;
            if (frames >= maxFrames) return frames;

            if (stats.ElapsedMilliseconds >= 2_000 && fpsMark.ElapsedMilliseconds >= 2_000)
            {
                Status.Emit("fps", ((frames - fpsFrames) * 1000.0 / fpsMark.ElapsedMilliseconds).ToString("F1", System.Globalization.CultureInfo.InvariantCulture));
                fpsFrames = frames; fpsMark.Restart();
            }
            if (stats.ElapsedMilliseconds >= 10_000)
            {
                Log.Info($"{frames} kare kodlandi ({captured} yakalandi), {encoder.Stats()}");
                stats.Restart();
            }
        }
    }

    public void Dispose()
    {
        encoder?.Dispose();
        cursor?.Dispose();
        foreach (var v in vpOut) v?.Dispose();
        foreach (var t in nv12) t?.Dispose();
        vpIn?.Dispose(); vp?.Dispose(); vpEnum?.Dispose(); work?.Dispose();
        dup?.Dispose();
        videoContext?.Dispose(); videoDevice?.Dispose();
        context?.Dispose(); device?.Dispose();
    }
}

/// Desktop Duplication imleci kareye cizmez; biz ciziyoruz. Imlec bolgesi kucuk
/// oldugu icin CPU'da (staging doku uzerinden) karistiriliyor.
sealed class Cursor : IDisposable
{
    const int Max = 128;
    readonly ID3D11Device device;
    readonly ID3D11DeviceContext ctx;
    readonly ID3D11Texture2D target;
    readonly ID3D11Texture2D staging, backup;
    readonly int w, h;
    byte[] shape = Array.Empty<byte>();
    OutduplPointerShapeInfo shapeInfo;
    bool visible;
    int x, y;
    Box drawn;            // en son cizilen bolge (geri almak icin)
    bool hasDrawn;

    public Cursor(ID3D11Device device, ID3D11DeviceContext ctx, ID3D11Texture2D target, int w, int h)
    {
        this.device = device; this.ctx = ctx; this.target = target; this.w = w; this.h = h;
        var d = new Texture2DDescription
        {
            Width = Max, Height = Max, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read | CpuAccessFlags.Write
        };
        staging = device.CreateTexture2D(d);
        backup = device.CreateTexture2D(d with { Usage = ResourceUsage.Default, CPUAccessFlags = CpuAccessFlags.None });
    }

    public unsafe void Update(IDXGIOutputDuplication dup, OutduplFrameInfo info)
    {
        if (info.LastMouseUpdateTime != 0)
        {
            visible = info.PointerPosition.Visible;
            x = info.PointerPosition.Position.X; y = info.PointerPosition.Position.Y;
        }
        if (info.PointerShapeBufferSize > 0)
        {
            var buf = new byte[info.PointerShapeBufferSize];
            fixed (byte* p = buf)
            {
                if (dup.GetFramePointerShape((uint)buf.Length, (IntPtr)p, out _, out var si).Success)
                {
                    shape = buf; shapeInfo = si;
                }
            }
        }
    }

    // Imlec tipleri: 1 = tek renk (AND/XOR maskesi), 2 = renkli (alfa), 4 = maskeli renkli
    public unsafe void DrawInto()
    {
        hasDrawn = false;
        if (!visible || shape.Length == 0) return;
        int type = (int)shapeInfo.Type;
        int sw = (int)shapeInfo.Width, sh = (int)(type == 1 ? shapeInfo.Height / 2 : shapeInfo.Height);
        int left = x, top = y;
        int x0 = Math.Max(0, left), y0 = Math.Max(0, top);
        int x1 = Math.Min(w, left + Math.Min(sw, Max)), y1 = Math.Min(h, top + Math.Min(sh, Max));
        if (x1 <= x0 || y1 <= y0) return;

        drawn = new Box(x0, y0, 0, x1, y1, 1);
        var local = new Box(0, 0, 0, x1 - x0, y1 - y0, 1);
        ctx.CopySubresourceRegion(backup, 0, 0, 0, 0, target, 0, drawn);    // altindaki goruntuyu sakla
        ctx.CopySubresourceRegion(staging, 0, 0, 0, 0, target, 0, drawn);
        var map = ctx.Map(staging, 0, MapMode.ReadWrite);
        try
        {
            int pitch = (int)shapeInfo.Pitch;
            for (int row = y0; row < y1; row++)
            {
                byte* dst = (byte*)map.DataPointer + (row - y0) * map.RowPitch;
                int sy = row - top;
                for (int col = x0; col < x1; col++)
                {
                    int sx = col - left;
                    byte* d = dst + (col - x0) * 4;
                    if (type == 2)   // renkli, on-carpimsiz alfa
                    {
                        int o = sy * pitch + sx * 4;
                        int a = shape[o + 3];
                        if (a == 0) continue;
                        for (int c = 0; c < 3; c++) d[c] = (byte)((shape[o + c] * a + d[c] * (255 - a)) / 255);
                    }
                    else if (type == 4)   // maskeli renkli: alfa 0xFF ise XOR, 0 ise kopyala
                    {
                        int o = sy * pitch + sx * 4;
                        if (shape[o + 3] == 0xFF) { d[0] ^= shape[o]; d[1] ^= shape[o + 1]; d[2] ^= shape[o + 2]; }
                        else { d[0] = shape[o]; d[1] = shape[o + 1]; d[2] = shape[o + 2]; }
                    }
                    else   // tek renk: ust yari AND, alt yari XOR maskesi
                    {
                        int bit = 0x80 >> (sx & 7);
                        bool and = (shape[sy * pitch + sx / 8] & bit) != 0;
                        bool xor = (shape[(sy + sh) * pitch + sx / 8] & bit) != 0;
                        for (int c = 0; c < 3; c++)
                        {
                            byte v = and ? d[c] : (byte)0;
                            d[c] = xor ? (byte)(v ^ 0xFF) : v;
                        }
                    }
                }
            }
        }
        finally { ctx.Unmap(staging, 0); }
        ctx.CopySubresourceRegion(target, 0, (uint)x0, (uint)y0, 0, staging, 0, local);
        hasDrawn = true;
    }

    public void EraseFrom()
    {
        if (!hasDrawn) return;
        ctx.CopySubresourceRegion(target, 0, (uint)drawn.Left, (uint)drawn.Top, 0, backup, 0,
            new Box(0, 0, 0, drawn.Right - drawn.Left, drawn.Bottom - drawn.Top, 1));
        hasDrawn = false;
    }

    public void Dispose() { staging.Dispose(); backup.Dispose(); }
}

/// Sanal ekrani adiyla bulur ve DXGI adaptor + cikti olarak dondurur. Ekranin
/// sahibi olan adaptoru kullanmak hibrit (tumlesik + harici kart) sistemlerde sart.
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
    static extern bool EnumDisplayDevices(string? dev, uint i, ref DISPLAY_DEVICE dd, uint flags);

    public static string? FindVirtualDisplay()
    {
        for (uint i = 0; i < 64; i++)
        {
            var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            if (dd.DeviceString == "Virtual Display Driver" && (dd.StateFlags & 1) != 0) return dd.DeviceName;
        }
        return null;
    }

    public static (IDXGIAdapter1, IDXGIOutput)? FindOutput(string deviceName)
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        for (uint a = 0; factory.EnumAdapters1(a, out var adapter).Success; a++)
        {
            for (uint o = 0; adapter.EnumOutputs(o, out var output).Success; o++)
            {
                if (string.Equals(output.Description.DeviceName, deviceName, StringComparison.OrdinalIgnoreCase))
                    return (adapter, output);
                output.Dispose();
            }
            adapter.Dispose();
        }
        return null;
    }
}
