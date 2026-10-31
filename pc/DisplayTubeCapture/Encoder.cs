using System.Diagnostics;
using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;

namespace DisplayTube;

interface IVideoEncoder : IDisposable
{
    string Name { get; }
    /// NV12 dokuyu kodla; cikan paketler sink'e yazilir.
    void Encode(ID3D11Texture2D nv12, long pts100ns, PacketSink sink);
    string Stats();
}

static class EncoderFactory
{
    static bool started;

    public static IVideoEncoder Create(ID3D11Device device, ID3D11DeviceContext ctx, Luid luid, int w, int h, Options opt)
    {
        if (!started) { MediaFactory.MFStartup(false).CheckError(); started = true; }
        if (!opt.Software)
        {
            foreach (var act in MfGuids.EnumEncoders(MfGuids.EnumHardware, luid))
            {
                string name = act.FriendlyName;
                try { return new HardwareMfEncoder(act.Activate, name, device, w, h, opt); }
                catch (Exception e) { Log.Info($"{name} kullanilamadi: {e.Message}"); }
            }
            Log.Info("Donanim H.264 kodlayici yok, yazilim kodlayiciya geciliyor");
        }
        foreach (var act in MfGuids.EnumEncoders(MfGuids.EnumSync, null))
        {
            try { return new SoftwareMfEncoder(act.Activate, act.FriendlyName, device, ctx, w, h, opt); }
            catch (Exception e) { Log.Info($"{act.FriendlyName} kullanilamadi: {e.Message}"); }
        }
        throw new Exception("Hicbir H.264 kodlayici calismadi");
    }
}

/// Ortak: tur ayarlari, ICodecAPI ile dusuk gecikme, cikis ayristirma, istatistik.
abstract class MfEncoderBase : IVideoEncoder
{
    protected readonly IMFTransform mft;
    protected readonly int w, h;
    protected readonly Options opt;
    byte[]? lastConfig;
    readonly Dictionary<long, long> inputTimes = new();   // pts -> Stopwatch zamani (kodlama suresi icin)
    long statFrames, statLatencyTicks, statMaxTicks;
    public string Name { get; }

    protected MfEncoderBase(IMFActivate act, string name, int w, int h, Options opt)
    {
        Name = name; this.w = w; this.h = h; this.opt = opt;
        mft = act.ActivateObject<IMFTransform>();
    }

    protected void ConfigureCodecApi()
    {
        var api = CodecApi.From(mft);
        if (api == null) { Log.Info("ICodecAPI yok, varsayilan ayarlar"); return; }
        CodecApi.Try(api, MfGuids.CODECAPI_AVLowLatencyMode, true, "dusuk gecikme modu");
        CodecApi.Try(api, MfGuids.CODECAPI_AVEncCommonRateControlMode, 0u, "CBR");   // eAVEncCommonRateControlMode_CBR
        CodecApi.Try(api, MfGuids.CODECAPI_AVEncCommonMeanBitRate, (uint)opt.Bitrate, "bit hizi");
        CodecApi.Try(api, MfGuids.CODECAPI_AVEncMPVDefaultBPictureCount, 0u, "B-kare yok");
        CodecApi.Try(api, MfGuids.CODECAPI_AVEncMPVGOPSize, (uint)(opt.Fps * 2), "GOP");
        CodecApi.Try(api, MfGuids.CODECAPI_AVEncCommonQualityVsSpeed, 33u, "hiz oncelikli");
        Marshal.ReleaseComObject(api);
    }

    protected void SetTypes()
    {
        using var outType = MediaFactory.MFCreateMediaType();
        outType.Set(MfGuids.MF_MT_MAJOR_TYPE, MfGuids.MFMediaType_Video);
        outType.Set(MfGuids.MF_MT_SUBTYPE, MfGuids.MFVideoFormat_H264);
        outType.Set(MfGuids.MF_MT_AVG_BITRATE, (uint)opt.Bitrate);
        MediaFactory.MFSetAttributeSize(outType, MfGuids.MF_MT_FRAME_SIZE, (uint)w, (uint)h);
        MediaFactory.MFSetAttributeRatio(outType, MfGuids.MF_MT_FRAME_RATE, (uint)opt.Fps, 1);
        MediaFactory.MFSetAttributeRatio(outType, MfGuids.MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        outType.Set(MfGuids.MF_MT_INTERLACE_MODE, 2u);            // ilerlemeli (progressive)
        outType.Set(MfGuids.MF_MT_MPEG2_PROFILE, 77u);            // Main (B-kare kapali)
        mft.SetOutputType(0, outType, 0);

        using var inType = MediaFactory.MFCreateMediaType();
        inType.Set(MfGuids.MF_MT_MAJOR_TYPE, MfGuids.MFMediaType_Video);
        inType.Set(MfGuids.MF_MT_SUBTYPE, MfGuids.MFVideoFormat_NV12);
        MediaFactory.MFSetAttributeSize(inType, MfGuids.MF_MT_FRAME_SIZE, (uint)w, (uint)h);
        MediaFactory.MFSetAttributeRatio(inType, MfGuids.MF_MT_FRAME_RATE, (uint)opt.Fps, 1);
        MediaFactory.MFSetAttributeRatio(inType, MfGuids.MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        inType.Set(MfGuids.MF_MT_INTERLACE_MODE, 2u);
        mft.SetInputType(0, inType, 0);
    }

    protected void MarkInput(long pts) { lock (inputTimes) inputTimes[pts] = Stopwatch.GetTimestamp(); }

    /// Bir cikis ornegini paket(ler)e cevirip gonderir.
    protected unsafe void Emit(IMFSample sample, PacketSink sink)
    {
        long pts = sample.SampleTime;
        lock (inputTimes)
        {
            if (inputTimes.Remove(pts, out long t0))
            {
                long d = Stopwatch.GetTimestamp() - t0;
                statFrames++; statLatencyTicks += d; if (d > statMaxTicks) statMaxTicks = d;
            }
            if (inputTimes.Count > 64) inputTimes.Clear();
        }
        using var buf = sample.ConvertToContiguousBuffer();
        buf.Lock(out IntPtr p, out _, out int len);
        try
        {
            var data = new ReadOnlySpan<byte>((void*)p, len);
            // SPS/PPS degistiyse once ayar paketi gonder (decoder bununla kurulur).
            var cfg = AnnexB.ExtractConfig(data);
            if (cfg != null && (lastConfig == null || !cfg.AsSpan().SequenceEqual(lastConfig)))
            {
                lastConfig = cfg;
                sink.Send(PacketSink.Config, cfg);
            }
            if (lastConfig == null) return;   // ayar gelmeden kare gondermenin anlami yok
            sink.Send(AnnexB.HasIdr(data) ? PacketSink.KeyFrame : PacketSink.Frame, data);
        }
        finally { buf.Unlock(); }
    }

    public string Stats()
    {
        lock (inputTimes)
        {
            if (statFrames == 0) return "kodlama suresi: -";
            double f = 1000.0 / Stopwatch.Frequency;
            string s = $"kodlama suresi: ort {statLatencyTicks * f / statFrames:F1} ms, maks {statMaxTicks * f:F1} ms";
            statFrames = statLatencyTicks = statMaxTicks = 0;
            return s;
        }
    }

    public abstract void Encode(ID3D11Texture2D nv12, long pts100ns, PacketSink sink);

    public virtual void Dispose()
    {
        try { mft.ProcessMessage(Msg.NotifyEndStreaming, UIntPtr.Zero); } catch { }
        mft.Dispose();
    }
}

/// Donanim kodlayici (asenkron MFT). Dokular dogrudan GPU'dan verilir (kopya yok).
/// Olay dongusu ayri bir thread'de: cikis hazir olunca aninda gonderilir.
sealed class HardwareMfEncoder : MfEncoderBase
{
    readonly IMFDXGIDeviceManager manager;
    readonly IMFMediaEventGenerator events;
    readonly SemaphoreSlim needInput = new(0);
    readonly object mftLock = new();
    readonly Thread eventThread;
    volatile bool stopping;
    volatile Exception? failure;
    PacketSink? sink;

    public HardwareMfEncoder(IMFActivate act, string name, ID3D11Device device, int w, int h, Options opt)
        : base(act, name, w, h, opt)
    {
        using (var attrs = mft.Attributes)
        {
            attrs.Set(MfGuids.MF_TRANSFORM_ASYNC_UNLOCK, 1u);
            attrs.Set(MfGuids.MF_LOW_LATENCY, 1u);
        }
        manager = MediaFactory.MFCreateDXGIDeviceManager();
        manager.ResetDevice(device).CheckError();
        mft.ProcessMessage(Msg.SetD3DManager, (UIntPtr)(ulong)manager.NativePointer);

        ConfigureCodecApi();
        SetTypes();
        events = mft.QueryInterface<IMFMediaEventGenerator>();
        mft.ProcessMessage(Msg.NotifyBeginStreaming, UIntPtr.Zero);
        mft.ProcessMessage(Msg.NotifyStartOfStream, UIntPtr.Zero);

        eventThread = new Thread(EventLoop) { IsBackground = true, Name = "MFT olaylari" };
        eventThread.Start();
    }

    void EventLoop()
    {
        try
        {
            while (!stopping)
            {
                using var ev = events.GetEvent(0);   // engelleyici
                switch (ev.EventType)
                {
                    case MediaEventTypes.TransformNeedInput:
                        needInput.Release();
                        break;
                    case MediaEventTypes.TransformHaveOutput:
                        DrainOne();
                        break;
                }
            }
        }
        catch (Exception e) when (!stopping) { failure = e; needInput.Release(); }
        catch { }
    }

    void DrainOne()
    {
        var odb = new OutputDataBuffer { StreamID = 0 };
        Result r;
        lock (mftLock) r = mft.ProcessOutput(ProcessOutputFlags.None, 1, ref odb, out _);
        if (r.Code == MfGuids.MF_E_TRANSFORM_STREAM_CHANGE)
        {
            // Kodlayici cikis turunu yeniden istiyor (bazi suruculer ilk karede yapar).
            lock (mftLock)
            {
                using var t = mft.GetOutputAvailableType(0, 0);
                mft.SetOutputType(0, t, 0);
            }
            return;
        }
        r.CheckError();
        using (odb.Sample)
        {
            odb.Events?.Dispose();
            if (sink != null && odb.Sample != null) Emit(odb.Sample, sink);
        }
    }

    public override void Encode(ID3D11Texture2D nv12, long pts, PacketSink sink)
    {
        this.sink = sink;
        // Kodlayici yeni girdi isteyene kadar bekle (dusuk gecikme modunda genelde hemen).
        if (!needInput.Wait(2000)) throw new Exception("Kodlayici girdi istemiyor (takildi)");
        if (failure != null) throw failure is ClientGoneException ? failure : new Exception("Kodlayici hatasi: " + failure.Message, failure);
        if (sink.Gone) throw new ClientGoneException();

        using var buffer = MediaFactory.MFCreateDXGISurfaceBuffer(typeof(ID3D11Texture2D).GUID, nv12, 0, false);
        using var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = pts;
        sample.SampleDuration = 10_000_000L / opt.Fps;
        MarkInput(pts);
        lock (mftLock) mft.ProcessInput(0, sample, 0);
    }

    public override void Dispose()
    {
        stopping = true;
        try { mft.ProcessMessage(Msg.CommandFlush, UIntPtr.Zero); } catch { }
        try { mft.ProcessMessage(Msg.NotifyEndStreaming, UIntPtr.Zero); } catch { }
        try { using var g = mft.QueryInterface<IMFShutdown>(); g.Shutdown(); } catch { }   // GetEvent'i serbest birakir
        eventThread.Join(1000);
        events.Dispose();
        mft.Dispose();
        manager.Dispose();
    }
}

/// Yazilim kodlayici (senkron MFT). Donanim kodlayici olmayan sistemler icin yedek:
/// NV12 doku CPU'ya okunup bellekten verilir.
sealed class SoftwareMfEncoder : MfEncoderBase
{
    readonly ID3D11DeviceContext ctx;
    readonly ID3D11Texture2D staging;
    readonly int outSize;
    readonly bool providesSamples;

    public SoftwareMfEncoder(IMFActivate act, string name, ID3D11Device device, ID3D11DeviceContext ctx, int w, int h, Options opt)
        : base(act, name, w, h, opt)
    {
        this.ctx = ctx;
        ConfigureCodecApi();
        SetTypes();
        var info = mft.GetOutputStreamInfo(0);
        outSize = Math.Max((int)info.Size, w * h * 3 / 2);
        providesSamples = (info.Flags & 0x100) != 0;   // MFT_OUTPUT_STREAM_PROVIDES_SAMPLES
        staging = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w, Height = (uint)h, MipLevels = 1, ArraySize = 1, Format = Format.NV12,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging, CPUAccessFlags = CpuAccessFlags.Read
        });
        mft.ProcessMessage(Msg.NotifyBeginStreaming, UIntPtr.Zero);
        mft.ProcessMessage(Msg.NotifyStartOfStream, UIntPtr.Zero);
    }

    public override unsafe void Encode(ID3D11Texture2D nv12, long pts, PacketSink sink)
    {
        ctx.CopyResource(staging, nv12);
        var map = ctx.Map(staging, 0, MapMode.Read);
        IMFMediaBuffer buf;
        try
        {
            int size = w * h * 3 / 2;
            buf = MediaFactory.MFCreateMemoryBuffer(size);
            buf.Lock(out IntPtr dst, out _, out _);
            byte* s = (byte*)map.DataPointer, d = (byte*)dst;
            for (int row = 0; row < h * 3 / 2; row++)   // Y duzlemi + UV duzlemi, satir satir (pitch farkli olabilir)
                Buffer.MemoryCopy(s + row * map.RowPitch, d + row * w, w, w);
            buf.Unlock();
            buf.CurrentLength = size;
        }
        finally { ctx.Unmap(staging, 0); }

        using (buf)
        using (var sample = MediaFactory.MFCreateSample())
        {
            sample.AddBuffer(buf);
            sample.SampleTime = pts;
            sample.SampleDuration = 10_000_000L / opt.Fps;
            MarkInput(pts);
            mft.ProcessInput(0, sample, 0);
        }

        while (true)
        {
            IMFSample? outSample = null;
            if (!providesSamples)
            {
                outSample = MediaFactory.MFCreateSample();
                using var ob = MediaFactory.MFCreateMemoryBuffer(outSize);
                outSample.AddBuffer(ob);
            }
            var odb = new OutputDataBuffer { StreamID = 0, Sample = outSample! };
            var r = mft.ProcessOutput(ProcessOutputFlags.None, 1, ref odb, out _);
            if (r.Code == MfGuids.MF_E_TRANSFORM_NEED_MORE_INPUT) { outSample?.Dispose(); break; }
            r.CheckError();
            using (odb.Sample) Emit(odb.Sample!, sink);
        }
    }

    public override void Dispose() { staging.Dispose(); base.Dispose(); }
}

/// Annex-B yardimcilari.
static class AnnexB
{
    public static IEnumerable<(int start, int end)> Nals(ReadOnlySpan<byte> d) => NalList(d.ToArray());

    static List<(int, int)> NalList(byte[] d)
    {
        var r = new List<(int, int)>();
        int i = 0, cur = -1;
        while (i + 3 <= d.Length)
        {
            if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1)
            {
                if (cur >= 0) r.Add((cur, i > 0 && d[i - 1] == 0 ? i - 1 : i));
                cur = i + 3; i += 3;
            }
            else i++;
        }
        if (cur >= 0 && cur < d.Length) r.Add((cur, d.Length));
        return r;
    }

    /// SPS (7) ve PPS (8) NAL'larini baslangic kodlariyla birlestirir; yoksa null.
    public static byte[]? ExtractConfig(ReadOnlySpan<byte> d)
    {
        byte[]? sps = null, pps = null;
        var arr = d.ToArray();
        foreach (var (s, e) in NalList(arr))
        {
            int t = arr[s] & 0x1f;
            if (t == 7) sps = arr[s..e];
            else if (t == 8) pps = arr[s..e];
        }
        if (sps == null || pps == null) return null;
        var o = new byte[8 + sps.Length + pps.Length];
        o[3] = 1; sps.CopyTo(o, 4);
        o[4 + sps.Length + 3] = 1; pps.CopyTo(o, 8 + sps.Length);
        return o;
    }

    public static bool HasIdr(ReadOnlySpan<byte> d)
    {
        for (int i = 0; i + 3 < d.Length; i++)
            if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && (d[i + 3] & 0x1f) == 5) return true;
        return false;
    }
}

/// ICodecAPI (Vortice'te yok): kodlayici ozelliklerini ayarlamak icin.
[ComImport, Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICodecAPI
{
    [PreserveSig] int IsSupported(ref Guid api);
    [PreserveSig] int IsModifiable(ref Guid api);
    [PreserveSig] int GetParameterRange(ref Guid api, IntPtr a, IntPtr b, IntPtr c);
    [PreserveSig] int GetParameterValues(ref Guid api, IntPtr a, IntPtr b);
    [PreserveSig] int GetDefaultValue(ref Guid api, IntPtr v);
    [PreserveSig] int GetValue(ref Guid api, IntPtr v);
    [PreserveSig] int SetValue(ref Guid api, [In, MarshalAs(UnmanagedType.Struct)] ref object value);
}

static class CodecApi
{
    public static ICodecAPI? From(IMFTransform mft)
    {
        try { return (ICodecAPI)Marshal.GetObjectForIUnknown(mft.NativePointer); }
        catch { return null; }
    }

    public static void Try(ICodecAPI api, Guid key, object value, string what)
    {
        int hr = api.IsSupported(ref key);
        if (hr != 0) { Log.Info($"  {what}: desteklenmiyor"); return; }
        hr = api.SetValue(ref key, ref value);
        if (hr != 0) Log.Info($"  {what}: ayarlanamadi (0x{hr:X8})");
    }
}

static class MfGuids
{
    public static readonly Guid MF_MT_MAJOR_TYPE = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid MF_MT_SUBTYPE = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid MF_MT_FRAME_SIZE = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid MF_MT_FRAME_RATE = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid MF_MT_AVG_BITRATE = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid MF_MT_INTERLACE_MODE = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid MF_MT_PIXEL_ASPECT_RATIO = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    public static readonly Guid MF_MT_MPEG2_PROFILE = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    public static readonly Guid MFMediaType_Video = new("73646976-0000-0010-8000-00aa00389b71");
    public static readonly Guid MFVideoFormat_H264 = new("34363248-0000-0010-8000-00aa00389b71");
    public static readonly Guid MFVideoFormat_NV12 = new("3231564e-0000-0010-8000-00aa00389b71");
    public static readonly Guid MF_TRANSFORM_ASYNC_UNLOCK = new("e5666d6b-3422-4eb6-a421-da7db1f8e207");
    public static readonly Guid MF_LOW_LATENCY = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid MFT_CATEGORY_VIDEO_ENCODER = new("f79eac7d-e545-4387-bdee-d647d7bde42a");
    public static readonly Guid MFT_ENUM_ADAPTER_LUID = new("1d39518c-e220-4da8-a07f-ba172552d6b1");
    public static readonly Guid MFT_FRIENDLY_NAME_Attribute = new("314ffbae-5b41-4c95-9c19-4e7d586face3");

    public static readonly Guid CODECAPI_AVLowLatencyMode = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid CODECAPI_AVEncCommonRateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    public static readonly Guid CODECAPI_AVEncCommonMeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    public static readonly Guid CODECAPI_AVEncMPVDefaultBPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    public static readonly Guid CODECAPI_AVEncMPVGOPSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    public static readonly Guid CODECAPI_AVEncCommonQualityVsSpeed = new("98332df8-03cd-476b-89fa-3f9e442dec9f");

    public const int MF_E_TRANSFORM_STREAM_CHANGE = unchecked((int)0xC00D6D61);
    public const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);

    public const uint EnumSync = 0x1, EnumHardware = 0x4, EnumSortAndFilter = 0x40;

    public record Encoder(IMFActivate Activate, string FriendlyName);

    /// H.264 kodlayicilari listeler; luid verilirse yalnizca o ekran kartininkiler (hibrit sistemler).
    public static List<Encoder> EnumEncoders(uint flags, Luid? luid)
    {
        var input = new RegisterTypeInfo { GuidMajorType = MFMediaType_Video, GuidSubtype = MFVideoFormat_NV12 };
        var output = new RegisterTypeInfo { GuidMajorType = MFMediaType_Video, GuidSubtype = MFVideoFormat_H264 };
        using var attrs = MediaFactory.MFCreateAttributes(1);
        if (luid is Luid l)
        {
            var blob = new byte[8];
            BitConverter.GetBytes(l.LowPart).CopyTo(blob, 0);
            BitConverter.GetBytes(l.HighPart).CopyTo(blob, 4);
            attrs.SetBlob(MFT_ENUM_ADAPTER_LUID, blob);
        }
        MediaFactory.MFTEnum2(MFT_CATEGORY_VIDEO_ENCODER, flags | EnumSortAndFilter, input, output, attrs, out IntPtr arr, out uint count);
        var list = new List<Encoder>();
        for (int i = 0; i < count; i++)
        {
            var act = new IMFActivate(Marshal.ReadIntPtr(arr, i * IntPtr.Size));
            string name;
            try { name = act.GetString(MFT_FRIENDLY_NAME_Attribute); } catch { name = "H.264 kodlayici"; }
            list.Add(new Encoder(act, name));
        }
        if (arr != IntPtr.Zero) Marshal.FreeCoTaskMem(arr);
        return list;
    }
}

/// MFT mesajlari (mftransform.h MFT_MESSAGE_TYPE degerleri).
static class Msg
{
    public const TMessageType CommandFlush = (TMessageType)0x0;
    public const TMessageType SetD3DManager = (TMessageType)0x2;
    public const TMessageType NotifyBeginStreaming = (TMessageType)0x10000000;
    public const TMessageType NotifyEndStreaming = (TMessageType)0x10000001;
    public const TMessageType NotifyStartOfStream = (TMessageType)0x10000003;
}