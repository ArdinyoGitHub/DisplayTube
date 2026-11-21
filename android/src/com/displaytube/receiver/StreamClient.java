package com.displaytube.receiver;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.util.Log;
import android.view.MotionEvent;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;

/**
 * PC'deki DisplayTube sunucusundan paketleri okur: H.264 goruntuyu MediaCodec'e dusuk
 * gecikme modunda, PCM sesi AudioTrack'e verir; dokunuslari sunucuya gonderir.
 * Baglanti koparsa yeniden dener. Protokol: docs/PROTOKOL.md
 *
 * Paket bicimi (iki yonde de): [tur: 1 bayt][uzunluk: 4 bayt, big-endian][yuk]
 */
final class StreamClient implements MouseInput.Sink {

    static final int STATE_WAITING_PC = 0, STATE_CONNECTED = 1, STATE_STREAMING = 2;

    interface Listener { void onState(int state); }

    // Bilgisayar -> telefon
    static final int PACKET_CONFIG = 1;
    static final int PACKET_KEY_FRAME = 2;
    static final int PACKET_FRAME = 3;
    static final int PACKET_SERVER_HELLO = 4;
    static final int PACKET_AUDIO_CONFIG = 5;
    static final int PACKET_AUDIO = 6;
    // Telefon -> bilgisayar
    static final int PACKET_HELLO = 0x80;
    static final int PACKET_TOUCH = 0x81;
    static final int PACKET_MOUSE = 0x82;

    static final int PROTOCOL_VERSION = 1;
    static final int CAP_TOUCH = 1, CAP_AUDIO = 2, CAP_MOUSE = 4;
    static final int MY_CAPS = CAP_TOUCH | CAP_AUDIO | CAP_MOUSE;

    private static final String TAG = "DisplayTube";
    private static final int RETRY_MS = 500;
    private static final int MAX_POINTERS = 10;

    private final String host;
    private final int port;
    private final Surface surface;
    private final Listener listener;
    private final int screenW, screenH;

    // Olcum (logcat'e 120 karede bir yazilir)
    private static volatile int droppedInput;
    private int statFrames;
    private long statSum, statMax;

    private volatile boolean running;
    private volatile Socket socket;
    private volatile int serverCaps;   // 0: sunucu SERVER_HELLO gondermedi (eski surum) -> dokunus gonderme
    private Thread thread;

    // Giden paketler: ag thread'i okurken yazmak icin ayri bir yazici thread. Kuyruk dolarsa
    // (sunucu okumuyorsa) paket atilir; UI thread hic beklemez.
    private final BlockingQueue<byte[]> outQueue = new ArrayBlockingQueue<>(128);
    private volatile Thread writer;

    StreamClient(String host, int port, Surface surface, Listener listener, int screenW, int screenH) {
        this.host = host;
        this.port = port;
        this.surface = surface;
        this.listener = listener;
        this.screenW = screenW;
        this.screenH = screenH;
    }

    void start() {
        running = true;
        thread = new Thread(new Runnable() {
            @Override public void run() { loop(); }
        }, "DisplayTube-net");
        thread.start();
    }

    void stop() {
        running = false;
        closeQuietly();
        if (thread != null) {
            thread.interrupt();
            try { thread.join(1000); } catch (InterruptedException ignored) { }
        }
    }

    // ------------------------------------------------------------ dokunus

    /** Sunucu fare kipini sectiyse true (bkz. MouseInput); degilse dokunuslar sendTouch ile gider. */
    boolean mouseMode() { return (serverCaps & CAP_MOUSE) != 0; }

    /** MOUSE paketi: u8 dugmeler, u16 x, u16 y (0..65535), i16 dikey/yatay tekerlek (1/120 centik). */
    @Override
    public void sendMouse(int buttons, int x, int y, int wheelV, int wheelH) {
        if ((serverCaps & CAP_MOUSE) == 0) return;
        byte[] p = new byte[5 + 9];
        int o = header(p, PACKET_MOUSE, 9);
        p[o++] = (byte) buttons;
        p[o++] = (byte) (x >> 8); p[o++] = (byte) x;
        p[o++] = (byte) (y >> 8); p[o++] = (byte) y;
        p[o++] = (byte) (wheelV >> 8); p[o++] = (byte) wheelV;
        p[o++] = (byte) (wheelH >> 8); p[o] = (byte) wheelH;
        outQueue.offer(p);
    }

    /**
     * UI thread'inden cagrilir. viewW/viewH: goruntunun cizildigi alanin boyutu.
     * O anda ekrandaki butun parmaklari, kalkan parmagi da basili=0 olarak gonderir.
     */
    void sendTouch(MotionEvent e, int viewW, int viewH) {
        if ((serverCaps & CAP_TOUCH) == 0 || viewW <= 0 || viewH <= 0) return;
        int action = e.getActionMasked();
        int liftedIndex = -1;
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_POINTER_UP) liftedIndex = e.getActionIndex();
        boolean cancel = action == MotionEvent.ACTION_CANCEL;

        int n = Math.min(e.getPointerCount(), MAX_POINTERS);
        byte[] p = new byte[5 + 1 + n * 6];
        int o = header(p, PACKET_TOUCH, 1 + n * 6);
        p[o++] = (byte) n;
        for (int i = 0; i < n; i++) {
            int id = e.getPointerId(i);
            boolean down = !cancel && i != liftedIndex;
            int x = norm(e.getX(i), viewW), y = norm(e.getY(i), viewH);
            p[o++] = (byte) id;
            p[o++] = (byte) (down ? 1 : 0);
            p[o++] = (byte) (x >> 8); p[o++] = (byte) x;
            p[o++] = (byte) (y >> 8); p[o++] = (byte) y;
        }
        outQueue.offer(p);
    }

    private static int norm(float v, int size) {
        int r = Math.round(v * 65535f / (size - 1));
        return r < 0 ? 0 : (r > 65535 ? 65535 : r);
    }

    private static int header(byte[] p, int type, int len) {
        p[0] = (byte) type;
        p[1] = (byte) (len >>> 24); p[2] = (byte) (len >>> 16); p[3] = (byte) (len >>> 8); p[4] = (byte) len;
        return 5;
    }

    private byte[] helloPacket() {
        byte[] p = new byte[5 + 10];
        int o = header(p, PACKET_HELLO, 10);
        p[o++] = (byte) (PROTOCOL_VERSION >> 8); p[o++] = (byte) PROTOCOL_VERSION;
        p[o++] = (byte) (MY_CAPS >>> 24); p[o++] = (byte) (MY_CAPS >>> 16); p[o++] = (byte) (MY_CAPS >>> 8); p[o++] = (byte) MY_CAPS;
        p[o++] = (byte) (screenW >> 8); p[o++] = (byte) screenW;
        p[o++] = (byte) (screenH >> 8); p[o] = (byte) screenH;
        return p;
    }

    private void startWriter(final OutputStream out) {
        outQueue.clear();
        outQueue.offer(helloPacket());
        Thread w = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    while (running) {
                        byte[] p = outQueue.take();
                        out.write(p);
                        out.flush();
                    }
                } catch (InterruptedException ignored) {
                } catch (IOException e) {
                    Log.w(TAG, "Yazilamadi: " + e);
                }
            }
        }, "DisplayTube-write");
        writer = w;
        w.start();
    }

    private void stopWriter() {
        Thread w = writer;
        writer = null;
        if (w != null) {
            w.interrupt();
            try { w.join(500); } catch (InterruptedException ignored) { }
        }
    }

    // ------------------------------------------------------------ oturum

    private void loop() {
        while (running) {
            try {
                session();
            } catch (Exception e) {
                Log.w(TAG, "Oturum bitti: " + e);
            }
            if (!running) break;
            listener.onState(STATE_WAITING_PC);
            try { Thread.sleep(RETRY_MS); } catch (InterruptedException e) { break; }
        }
    }

    private void session() throws IOException {
        Socket s = new Socket();
        socket = s;
        serverCaps = 0;
        s.setTcpNoDelay(true);
        s.setReceiveBufferSize(1 << 20);
        s.connect(new InetSocketAddress(host, port), 2000);
        listener.onState(STATE_CONNECTED);
        startWriter(s.getOutputStream());

        MediaCodec codec = null;
        Thread drain = null;
        AudioTrack audio = null;
        try {
            DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream(), 1 << 16));
            byte[] buf = new byte[1 << 20];
            boolean started = false;
            byte[] lastConfig = null;

            while (running) {
                int type = in.readUnsignedByte();
                int len = in.readInt();
                if (len < 0 || len > (64 << 20)) throw new IOException("Gecersiz paket boyu: " + len);
                if (len > buf.length) buf = new byte[len];
                in.readFully(buf, 0, len);

                switch (type) {
                    case PACKET_SERVER_HELLO:
                        if (len >= 6) {
                            serverCaps = ((buf[2] & 0xff) << 24) | ((buf[3] & 0xff) << 16) | ((buf[4] & 0xff) << 8) | (buf[5] & 0xff);
                            Log.i(TAG, "Sunucu protokol " + (((buf[0] & 0xff) << 8) | (buf[1] & 0xff)) + ", yetenekler " + serverCaps);
                        }
                        continue;
                    case PACKET_AUDIO_CONFIG:
                        if (audio != null) { audio.release(); audio = null; }
                        if (len >= 6) audio = createAudio(buf);
                        continue;
                    case PACKET_AUDIO:
                        // Bloklamadan yaz: tampon doluysa (saat kaymasi) fazlasi atilir, gecikme birikmez.
                        if (audio != null) audio.write(buf, 0, len & ~3, AudioTrack.WRITE_NON_BLOCKING);
                        continue;
                    case PACKET_CONFIG:
                    case PACKET_KEY_FRAME:
                    case PACKET_FRAME:
                        break;
                    default:
                        continue;   // bilinmeyen tur: atla
                }

                if (type == PACKET_CONFIG) {
                    // PC'de kodlayici yeniden baslayinca config tekrar gelir. Farkliysa
                    // (orn. cozunurluk degisti) decoder'i bastan kur.
                    if (codec != null && (lastConfig == null || !Arrays.equals(lastConfig, Arrays.copyOf(buf, len)))) {
                        Log.i(TAG, "Yeni akis ayari, decoder yeniden kuruluyor");
                        drain.interrupt();
                        try { codec.stop(); } catch (Exception ignored) { }
                        try { drain.join(500); } catch (InterruptedException ignored) { }
                        codec.release();
                        codec = null;
                        started = false;
                    }
                    lastConfig = Arrays.copyOf(buf, len);
                    if (codec == null) {
                        codec = createDecoder(buf, len);
                        final MediaCodec c = codec;
                        drain = new Thread(new Runnable() {
                            @Override public void run() { drainLoop(c); }
                        }, "DisplayTube-render");
                        drain.start();
                    }
                    continue;
                }
                if (codec == null) continue;
                // Ilk anahtar kareden once gelen kareleri atla.
                if (!started) {
                    if (type != PACKET_KEY_FRAME) continue;
                    started = true;
                    listener.onState(STATE_STREAMING);
                }
                queue(codec, buf, len);
            }
        } finally {
            closeQuietly();
            stopWriter();
            serverCaps = 0;
            if (audio != null) audio.release();
            if (codec != null) {
                try { codec.stop(); } catch (Exception ignored) { }
                if (drain != null) {
                    drain.interrupt();
                    try { drain.join(500); } catch (InterruptedException ignored) { }
                }
                codec.release();
            }
        }
    }

    private static AudioTrack createAudio(byte[] b) {
        int rate = ((b[0] & 0xff) << 24) | ((b[1] & 0xff) << 16) | ((b[2] & 0xff) << 8) | (b[3] & 0xff);
        int channels = b[4] & 0xff, format = b[5] & 0xff;
        if (format != 1 || (channels != 1 && channels != 2) || rate < 8000 || rate > 192000) {
            Log.w(TAG, "Desteklenmeyen ses bicimi: " + rate + " Hz, " + channels + " kanal, bicim " + format);
            return null;
        }
        int mask = channels == 2 ? AudioFormat.CHANNEL_OUT_STEREO : AudioFormat.CHANNEL_OUT_MONO;
        int min = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT);
        int frame = channels * 2;
        int size = Math.max(min * 2, rate / 1000 * 60 * frame);   // ~60 ms: kisa takilmalari yutar, gecikmeyi sinirlar
        try {
            AudioTrack t = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build())
                    .setAudioFormat(new AudioFormat.Builder()
                            .setSampleRate(rate)
                            .setChannelMask(mask)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .build())
                    .setBufferSizeInBytes(size)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                    .build();
            t.play();
            Log.i(TAG, "Ses: " + rate + " Hz, " + channels + " kanal, tampon " + t.getBufferSizeInFrames() + " kare");
            return t;
        } catch (Exception e) {
            Log.w(TAG, "AudioTrack acilamadi: " + e);
            return null;
        }
    }

    private MediaCodec createDecoder(byte[] config, int len) throws IOException {
        // Gercek boyut SPS'ten okunur; burada yalnizca baslangic degeri.
        MediaFormat f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080);
        byte[] csd = new byte[len];
        System.arraycopy(config, 0, csd, 0, len);
        f.setByteBuffer("csd-0", ByteBuffer.wrap(csd));   // SPS + PPS birlikte, Annex-B
        if (Build.VERSION.SDK_INT >= 30) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        f.setInteger(MediaFormat.KEY_PRIORITY, 0);         // gercek zamanli
        f.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE);
        MediaCodec c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        c.configure(f, surface, null, 0);
        c.start();
        Log.i(TAG, "Decoder: " + c.getName());
        return c;
    }

    private static void queue(MediaCodec codec, byte[] data, int len) {
        int idx;
        try {
            idx = codec.dequeueInputBuffer(100_000);
        } catch (IllegalStateException e) {
            return;
        }
        if (idx < 0) { droppedInput++; return; }  // decoder dolu; gecikme birikmesin diye kareyi at
        ByteBuffer b = codec.getInputBuffer(idx);
        b.clear();
        b.put(data, 0, len);
        codec.queueInputBuffer(idx, 0, len, System.nanoTime() / 1000, 0);
    }

    private void drainLoop(MediaCodec codec) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (running && !Thread.currentThread().isInterrupted()) {
            try {
                int idx = codec.dequeueOutputBuffer(info, 20_000);
                if (idx >= 0) {
                    codec.releaseOutputBuffer(idx, true);   // hemen ciz
                    // presentationTimeUs = paketin alindigi an; fark = cozme suresi.
                    long lat = System.nanoTime() / 1000 - info.presentationTimeUs;
                    statFrames++; statSum += lat; if (lat > statMax) statMax = lat;
                    if (statFrames == 120) {
                        Log.i(TAG, String.format("cozme gecikmesi: ort %.1f ms, maks %.1f ms, atilan %d",
                                statSum / 120 / 1000.0, statMax / 1000.0, droppedInput));
                        statFrames = 0; statSum = 0; statMax = 0;
                    }
                }
            } catch (IllegalStateException e) {
                return;  // codec durduruldu
            }
        }
    }

    private void closeQuietly() {
        Socket s = socket;
        if (s != null) {
            try { s.close(); } catch (IOException ignored) { }
        }
    }
}
