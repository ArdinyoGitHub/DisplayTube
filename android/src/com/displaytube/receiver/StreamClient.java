package com.displaytube.receiver;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.util.Log;
import android.view.Surface;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;

/**
 * PC'deki DisplayTubeServer'dan kare paketlerini okur ve MediaCodec'e dusuk
 * gecikme modunda verir. Baglanti koparsa yeniden dener.
 *
 * Paket bicimi (bkz. pc/DisplayTubeServer.cs):
 *   [tur: 1 bayt][uzunluk: 4 bayt, big-endian][Annex-B H.264]
 *   tur 1 = SPS+PPS, 2 = anahtar kare, 3 = kare
 */
final class StreamClient {

    interface Listener { void onStatus(String text); }

    static final int PACKET_CONFIG = 1;
    static final int PACKET_KEY_FRAME = 2;
    static final int PACKET_FRAME = 3;

    private static final String TAG = "DisplayTube";
    private static final int RETRY_MS = 500;
    private static final String WAITING = "PC bekleniyor...\nUSB ile bagla ve PC'de pc\\stream.ps1 calistir.";

    private final String host;
    private final int port;
    private final Surface surface;
    private final Listener listener;

    // Olcum (logcat'e 120 karede bir yazilir)
    private static volatile int droppedInput;
    private int statFrames;
    private long statSum, statMax;

    private volatile boolean running;
    private volatile Socket socket;
    private Thread thread;

    StreamClient(String host, int port, Surface surface, Listener listener) {
        this.host = host;
        this.port = port;
        this.surface = surface;
        this.listener = listener;
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

    private void loop() {
        while (running) {
            try {
                session();
            } catch (Exception e) {
                Log.w(TAG, "Oturum bitti: " + e);
            }
            if (!running) break;
            listener.onStatus(WAITING);
            try { Thread.sleep(RETRY_MS); } catch (InterruptedException e) { break; }
        }
    }

    private void session() throws IOException {
        Socket s = new Socket();
        socket = s;
        s.setTcpNoDelay(true);
        s.setReceiveBufferSize(1 << 20);
        s.connect(new InetSocketAddress(host, port), 2000);
        listener.onStatus("Baglandi, goruntu bekleniyor...");

        MediaCodec codec = null;
        Thread drain = null;
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

                if (type == PACKET_CONFIG) {
                    // PC'de ffmpeg yeniden baslayinca config tekrar gelir. Farkliysa
                    // (orn. cozunurluk degisti) decoder'i bastan kur.
                    if (codec != null && (lastConfig == null || !java.util.Arrays.equals(lastConfig, java.util.Arrays.copyOf(buf, len)))) {
                        Log.i(TAG, "Yeni akis ayari, decoder yeniden kuruluyor");
                        drain.interrupt();
                        try { codec.stop(); } catch (Exception ignored) { }
                        try { drain.join(500); } catch (InterruptedException ignored) { }
                        codec.release();
                        codec = null;
                        started = false;
                    }
                    lastConfig = java.util.Arrays.copyOf(buf, len);
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
                    listener.onStatus(null);
                }
                queue(codec, buf, len);
            }
        } finally {
            closeQuietly();
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
