// DisplayTube Linux sunucusu: EVDI sanal ekran -> H.264 (VAAPI / NVENC / x264) -> TCP 127.0.0.1:27183
// Telefon adb reverse ile baglanir. Kablo protokolu: [tur 1B][uzunluk 4B big-endian][yuk]
//   1 = ayar (SPS+PPS, Annex-B), 2 = anahtar kare, 3 = kare. Her paket tam bir kare.
//
// Kullanim: displaytube [--port 27183] [--size phone|WxH] [--bitrate 12000000] [--fps 60]
//                       [--encoder auto|vaapi|nvenc|x264] [--apk DisplayTube.apk] [--no-adb]
//           displaytube --check     (kurulum denetimi: evdi, adb, kodlayicilar)
// stdout'a durum satirlari: #client 0/1, #encoder <ad>, #size WxH, #fps <n>
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <evdi_lib.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <glob.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>

#define APP_PACKAGE "com.displaytube.receiver"
#define APP_COMPONENT APP_PACKAGE "/.MainActivity"
#define APK_VERSION_CODE 2     // android/AndroidManifest.xml ile ayni tutulmali
#ifndef DEFAULT_APK
#define DEFAULT_APK "/usr/local/share/displaytube/DisplayTube.apk"
#endif
#define PHONE_PORT 27183
#define BUF_ID 1
#define IDLE_RESEND_MS 250     // ekran durgunken ~4 FPS son kareyi tekrar gonder

// ---------------------------------------------------------------- ayarlar

static struct {
    int port, width, height, bitrate, fps, adb;
    const char *encoder, *apk;
} opt = {PHONE_PORT, 0, 0, 12000000, 60, 1, "auto", DEFAULT_APK};

static volatile sig_atomic_t stop;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void logi(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static int quiet;

static void status(const char *fmt, ...) {
    if (quiet) return;
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
    fflush(stdout);
}

// Masaustu bildirimi (freedesktop notify-send; her masaustunde ayni). Yoksa yalnizca log.
static void notify(const char *msg) {
    logi("%s", msg);
    pid_t pid = fork();
    if (pid == 0) {
        int fd = open("/dev/null", O_WRONLY);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); }
        execlp("notify-send", "notify-send", "-a", "DisplayTube", "-i", "video-display", "DisplayTube", msg, (char *)NULL);
        _exit(127);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
}

static int have_cmd(const char *name) {
    char cmd[128];
    snprintf(cmd, sizeof cmd, "command -v %s >/dev/null 2>&1", name);
    return system(cmd) == 0;
}

// ---------------------------------------------------------------- adb

static int run(const char *cmd, char *out, size_t outlen) {
    FILE *p = popen(cmd, "r");
    if (!p) return -1;
    size_t n = 0;
    if (out && outlen) {
        n = fread(out, 1, outlen - 1, p);
        out[n] = 0;
    } else {
        char tmp[512];
        while (fread(tmp, 1, sizeof tmp, p) > 0) { }
    }
    return pclose(p);
}

// "Physical size: 1080x2340" / "Override size: ..." -> son eslesme gecerli. Yatay dondurulur.
static int phone_size(int *w, int *h) {
    char out[512];
    if (run("adb shell wm size 2>/dev/null", out, sizeof out) != 0) return -1;
    int a = 0, b = 0;
    for (char *p = out; (p = strstr(p, "size:")); p++) sscanf(p, "size: %dx%d", &a, &b);
    if (a <= 0 || b <= 0) return -1;
    *w = (a > b ? a : b) & ~1;
    *h = (a > b ? b : a) & ~1;
    return 0;
}

// Telefondaki alici uygulamanin versionCode'u; kurulu degilse 0, okunamazsa -1.
static int phone_app_version(void) {
    char out[8192];
    if (run("adb shell dumpsys package " APP_PACKAGE " 2>/dev/null", out, sizeof out) != 0) return -1;
    char *p = strstr(out, "versionCode=");
    return p ? atoi(p + 12) : 0;
}

// Uygulama yoksa ya da eskiyse paketle gelen APK'yi kurar (Windows surumundeki gibi).
static void ensure_app(void) {
    int v = phone_app_version();
    if (v < 0 || v >= APK_VERSION_CODE) return;
    if (access(opt.apk, R_OK) != 0) {
        notify(v == 0 ? "Telefonda DisplayTube uygulamasi yok ve APK dosyasi bulunamadi. Yukleyiciyi yeniden calistirin."
                      : "Telefondaki DisplayTube uygulamasi eski ve APK dosyasi bulunamadi.");
        return;
    }
    logi(v == 0 ? "telefona uygulama kuruluyor: %s" : "telefondaki uygulama guncelleniyor: %s", opt.apk);
    char cmd[1200], out[2048];
    snprintf(cmd, sizeof cmd, "adb install -r '%s' 2>&1", opt.apk);
    if (run(cmd, out, sizeof out) != 0 || !strstr(out, "Success")) {
        char msg[1024];
        // Imza degistiyse guncelleme reddedilir; once kaldirmak gerekir.
        snprintf(msg, sizeof msg, "Telefona uygulama kurulamadi. %s\n%.300s",
                 strstr(out, "INSTALL_FAILED_UPDATE_INCOMPATIBLE")
                     ? "Imza farkli: telefondaki DisplayTube'u kaldirip tekrar deneyin."
                     : "Telefonda 'USB uzerinden yukle' iznini kontrol edin.",
                 out);
        notify(msg);
    }
}

// Kablo cikip takilinca adb reverse kaybolur; 2 sn'de bir kontrol edip kurar, uygulamayi acar.
static void *adb_watch(void *arg) {
    (void)arg;
    char rule[64], cmd[160], out[2048];
    snprintf(rule, sizeof rule, "tcp:%d", PHONE_PORT);
    if (!have_cmd("adb")) {
        notify("adb bulunamadi. Telefon baglantisi icin 'android-tools' (Debian/Ubuntu: 'adb') paketini kurun "
               "ya da yukleyiciyi yeniden calistirin.");
        return NULL;
    }
    int last_ok = -1, last_state = 0;
    while (!stop) {
        int ok = 0;
        // Cihaz durumu: yetkisiz (telefonda izin sorusu) ise kullaniciya soyle.
        int state = 0;   // 0 yok, 1 hazir, 2 yetkisiz
        if (run("adb devices 2>/dev/null", out, sizeof out) == 0) {
            if (strstr(out, "\tdevice")) state = 1;
            else if (strstr(out, "\tunauthorized")) state = 2;
        }
        if (state == 2 && last_state != 2)
            notify("Telefonda 'USB hata ayiklamaya izin ver' sorusunu onaylayin.");
        if (state == 1 && last_state != 1) ensure_app();
        last_state = state;
        if (run("adb reverse --list 2>/dev/null", out, sizeof out) == 0) {
            char want[96];
            snprintf(want, sizeof want, "%s tcp:%d", rule, opt.port);
            if (strstr(out, want)) ok = 1;
            else {
                snprintf(cmd, sizeof cmd, "adb reverse %s tcp:%d 2>&1", rule, opt.port);
                if (run(cmd, NULL, 0) == 0) {
                    logi("adb reverse %s -> tcp:%d kuruldu", rule, opt.port);
                    run("adb shell am start -n " APP_COMPONENT " 2>&1", NULL, 0);
                    ok = 1;
                }
            }
        }
        if (ok != last_ok && !ok) logi("telefon bekleniyor (adb)");
        last_ok = ok;
        for (int i = 0; i < 20 && !stop; i++) usleep(100000);
    }
    return NULL;
}

// ---------------------------------------------------------------- EDID

// EDID 1.3, tek detayli zamanlama (CVT reduced blanking), monitor adi "DisplayTube".
static void make_edid(unsigned char e[128], int w, int hgt, int hz) {
    memset(e, 0, 128);
    const unsigned char hdr[8] = {0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0};
    memcpy(e, hdr, 8);
    unsigned short m = ((('D' - '@') & 31) << 10) | ((('T' - '@') & 31) << 5) | (('B' - '@') & 31);
    e[8] = m >> 8; e[9] = m & 0xff;
    e[10] = 0x01;
    e[12] = 1;
    e[16] = 1; e[17] = 2026 - 1990;
    e[18] = 1; e[19] = 3;
    e[20] = 0x80;                          // dijital giris
    e[21] = 15; e[22] = 7;                 // cm
    e[23] = 0x78;                          // gamma 2.2
    e[24] = 0x0a;                          // RGB, ilk DTD tercih edilen kip
    const unsigned char chroma[10] = {0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54};
    memcpy(e + 25, chroma, 10);
    for (int i = 38; i < 54; i++) e[i] = 0x01;

    int hfp = 48, hs = 32, hbp = 80, htot = w + hfp + hs + hbp;
    double line_us = (1e6 / hz - 460.0) / hgt;
    int vbl = (int)(460.0 / line_us) + 1;
    if (vbl < 15) vbl = 15;
    int vfp = 3, vs = 6, vtot = hgt + vbl;
    long clk10k = ((long)htot * vtot * hz + 9999) / 10000;
    clk10k = (clk10k + 24) / 25 * 25;
    int hbl = htot - w;
    unsigned char *d = e + 54;
    d[0] = clk10k & 0xff; d[1] = clk10k >> 8;
    d[2] = w & 0xff; d[3] = hbl & 0xff; d[4] = ((w >> 8) << 4) | (hbl >> 8);
    d[5] = hgt & 0xff; d[6] = vbl & 0xff; d[7] = ((hgt >> 8) << 4) | (vbl >> 8);
    d[8] = hfp & 0xff; d[9] = hs & 0xff;
    d[10] = ((vfp & 15) << 4) | (vs & 15);
    d[11] = ((hfp >> 8) << 6) | ((hs >> 8) << 4) | ((vfp >> 4) << 2) | (vs >> 4);
    d[12] = 150; d[13] = 70;
    d[17] = 0x1a;

    d = e + 72;
    d[3] = 0xfc;
    memcpy(d + 5, "DisplayTube\n ", 13);
    d = e + 90;
    d[3] = 0xfd; d[5] = 24; d[6] = 75; d[7] = 30; d[8] = 160;
    d[9] = (unsigned char)(clk10k / 1000 + 1); d[11] = 0x0a;
    memset(d + 12, 0x20, 6);
    e[108 + 3] = 0x10;

    unsigned sum = 0;
    for (int i = 0; i < 127; i++) sum += e[i];
    e[127] = (unsigned char)(256 - (sum & 0xff));
}

// ---------------------------------------------------------------- istemci / paketler

static int client = -1;
static unsigned char client_cfg[512];
static int client_cfg_len = -1;     // -1: bu istemciye henuz ayar gonderilmedi

static void client_close(void) {
    if (client < 0) return;
    close(client);
    client = -1;
    status("#client 0");
}

static int send_all(const void *p, size_t n) {
    const unsigned char *b = p;
    while (n) {
        ssize_t r = send(client, b, n, MSG_NOSIGNAL);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        b += r; n -= (size_t)r;
    }
    return 0;
}

static void send_packet(int type, const unsigned char *data, size_t len) {
    if (client < 0) return;
    unsigned char hdr[5] = {(unsigned char)type, len >> 24, len >> 16, len >> 8, len};
    if (send_all(hdr, 5) || send_all(data, len)) {
        logi("istemciye yazilamadi: %s", strerror(errno));
        client_close();
    }
}

// Annex-B erisim biriminden SPS/PPS ayiklar, ayar degistiyse once ayar paketi gonderir.
static void on_encoded(const unsigned char *d, int n) {
    unsigned char cfg[512];
    int cfglen = 0, idr = 0;
    int i = 0;
    while (i + 3 <= n) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            int s = i + 3, e = s;
            while (e + 3 <= n && !(d[e] == 0 && d[e + 1] == 0 && (d[e + 2] == 1 || (d[e + 2] == 0 && e + 3 < n && d[e + 3] == 1)))) e++;
            if (e + 3 > n) e = n;
            int t = d[s] & 31;
            if (t == 5) idr = 1;
            if ((t == 7 || t == 8) && cfglen + 4 + (e - s) <= (int)sizeof cfg) {
                memcpy(cfg + cfglen, "\0\0\0\1", 4);
                memcpy(cfg + cfglen + 4, d + s, e - s);
                cfglen += 4 + (e - s);
            }
            i = e;
        } else i++;
    }
    if (cfglen && (cfglen != client_cfg_len || memcmp(cfg, client_cfg, cfglen))) {
        send_packet(1, cfg, cfglen);
        memcpy(client_cfg, cfg, cfglen);
        client_cfg_len = cfglen;
    }
    if (client_cfg_len < 0) return;   // ayar gelmeden kare gonderme
    send_packet(idr ? 2 : 3, d, n);
}

// ---------------------------------------------------------------- kodlayici

typedef struct {
    const char *name;
    AVBufferRef *hwdev;
    AVFilterGraph *graph;
    AVFilterContext *src, *sink;
    AVCodecContext *cc;
    struct SwsContext *sws;
    AVFrame *sw;            // x264 icin yuv420p
    int w, h;
    int64_t pts;
    int force_key;
} Encoder;

static Encoder enc;

static void enc_close(void) {
    avcodec_free_context(&enc.cc);
    avfilter_graph_free(&enc.graph);
    av_buffer_unref(&enc.hwdev);
    sws_freeContext(enc.sws);
    av_frame_free(&enc.sw);
    memset(&enc, 0, sizeof enc);
}

static AVCodecContext *codec_ctx(const char *name) {
    const AVCodec *c = avcodec_find_encoder_by_name(name);
    if (!c) return NULL;
    AVCodecContext *cc = avcodec_alloc_context3(c);
    cc->width = enc.w;
    cc->height = enc.h;
    cc->time_base = (AVRational){1, opt.fps};
    cc->framerate = (AVRational){opt.fps, 1};
    cc->gop_size = opt.fps * 2;
    cc->max_b_frames = 0;
    cc->bit_rate = opt.bitrate;
    cc->rc_max_rate = opt.bitrate;
    cc->rc_buffer_size = opt.bitrate / opt.fps * 2;   // ~2 kare: patlama sinirli
    cc->flags |= AV_CODEC_FLAG_LOW_DELAY;
    cc->profile = AV_PROFILE_H264_MAIN;
    return cc;
}

static int vaapi_open(void) {
    if (av_hwdevice_ctx_create(&enc.hwdev, AV_HWDEVICE_TYPE_VAAPI, NULL, NULL, 0) < 0) return -1;
    enc.graph = avfilter_graph_alloc();
    char args[256];
    snprintf(args, sizeof args, "video_size=%dx%d:pix_fmt=%d:time_base=1/%d:pixel_aspect=1/1",
             enc.w, enc.h, AV_PIX_FMT_BGR0, opt.fps);
    if (avfilter_graph_create_filter(&enc.src, avfilter_get_by_name("buffer"), "in", args, NULL, enc.graph) < 0 ||
        avfilter_graph_create_filter(&enc.sink, avfilter_get_by_name("buffersink"), "out", NULL, NULL, enc.graph) < 0)
        return -1;
    // BGRA -> VAAPI yuzeyi -> GPU'da NV12. Cihaz, filtre baslatilmadan once verilmeli.
    AVFilterContext *up = avfilter_graph_alloc_filter(enc.graph, avfilter_get_by_name("hwupload"), "up");
    AVFilterContext *conv = avfilter_graph_alloc_filter(enc.graph, avfilter_get_by_name("scale_vaapi"), "conv");
    if (!up || !conv) return -1;
    up->hw_device_ctx = av_buffer_ref(enc.hwdev);
    conv->hw_device_ctx = av_buffer_ref(enc.hwdev);
    if (avfilter_init_str(up, NULL) < 0 || avfilter_init_str(conv, "format=nv12") < 0 ||
        avfilter_link(enc.src, 0, up, 0) < 0 || avfilter_link(up, 0, conv, 0) < 0 ||
        avfilter_link(conv, 0, enc.sink, 0) < 0 || avfilter_graph_config(enc.graph, NULL) < 0)
        return -1;

    enc.cc = codec_ctx("h264_vaapi");
    if (!enc.cc) return -1;
    enc.cc->pix_fmt = AV_PIX_FMT_VAAPI;
    enc.cc->hw_frames_ctx = av_buffer_ref(av_buffersink_get_hw_frames_ctx(enc.sink));
    av_opt_set(enc.cc->priv_data, "rc_mode", "CBR", 0);
    av_opt_set_int(enc.cc->priv_data, "async_depth", 1, 0);
    return avcodec_open2(enc.cc, NULL, NULL) < 0 ? -1 : 0;
}

static int nvenc_open(void) {
    enc.cc = codec_ctx("h264_nvenc");
    if (!enc.cc) return -1;
    enc.cc->pix_fmt = AV_PIX_FMT_BGR0;       // NVENC renk donusumunu GPU'da yapar
    av_opt_set(enc.cc->priv_data, "preset", "p1", 0);
    av_opt_set(enc.cc->priv_data, "tune", "ull", 0);
    av_opt_set_int(enc.cc->priv_data, "zerolatency", 1, 0);
    av_opt_set(enc.cc->priv_data, "rc", "cbr", 0);
    return avcodec_open2(enc.cc, NULL, NULL) < 0 ? -1 : 0;
}

static int x264_open(void) {
    enc.cc = codec_ctx("libx264");
    if (!enc.cc) return -1;
    enc.cc->pix_fmt = AV_PIX_FMT_YUV420P;
    av_opt_set(enc.cc->priv_data, "preset", "ultrafast", 0);
    av_opt_set(enc.cc->priv_data, "tune", "zerolatency", 0);
    if (avcodec_open2(enc.cc, NULL, NULL) < 0) return -1;
    enc.sws = sws_getContext(enc.w, enc.h, AV_PIX_FMT_BGR0, enc.w, enc.h, AV_PIX_FMT_YUV420P,
                             SWS_POINT, NULL, NULL, NULL);
    enc.sw = av_frame_alloc();
    enc.sw->format = AV_PIX_FMT_YUV420P;
    enc.sw->width = enc.w;
    enc.sw->height = enc.h;
    return enc.sws && av_frame_get_buffer(enc.sw, 0) == 0 ? 0 : -1;
}

static void noop_free(void *o, uint8_t *d) { (void)o; (void)d; }

static int enc_frame(unsigned char *bgra, int stride, int deliver);

// Kodlayici zinciri: ilk calisan secilir (kisa oz test ile).
static int enc_open(int w, int h, unsigned char *testbuf, int stride) {
    static const struct { const char *name; int (*open)(void); } chain[] = {
        {"vaapi", vaapi_open}, {"nvenc", nvenc_open}, {"x264", x264_open}};
    for (unsigned i = 0; i < sizeof chain / sizeof *chain; i++) {
        if (strcmp(opt.encoder, "auto") && strcmp(opt.encoder, chain[i].name)) continue;
        enc_close();
        enc.w = w; enc.h = h;
        enc.name = chain[i].name;
        if (chain[i].open() == 0 && enc_frame(testbuf, stride, 0) == 0) {
            // Oz testten sonra temiz baslangic: yeniden ac ki ilk kare IDR olsun.
            enc_close();
            enc.w = w; enc.h = h;
            enc.name = chain[i].name;
            if (chain[i].open() == 0) {
                enc.force_key = 1;
                status("#encoder %s", enc.cc->codec->name);
                return 0;
            }
        }
        logi("kodlayici %s kullanilamadi", chain[i].name);
    }
    enc_close();
    return -1;
}

static int drain(int deliver) {
    AVPacket *pkt = av_packet_alloc();
    int r, got = 0;
    while ((r = avcodec_receive_packet(enc.cc, pkt)) == 0) {
        got = 1;
        if (deliver) on_encoded(pkt->data, pkt->size);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    return (r == AVERROR(EAGAIN) || r == AVERROR_EOF || got) ? 0 : -1;
}

static int enc_frame(unsigned char *bgra, int stride, int deliver) {
    AVFrame *f = av_frame_alloc();
    int r = -1;
    f->format = AV_PIX_FMT_BGR0;
    f->width = enc.w;
    f->height = enc.h;
    f->data[0] = bgra;
    f->linesize[0] = stride;
    f->buf[0] = av_buffer_create(bgra, (size_t)stride * enc.h, noop_free, NULL, 0);
    f->pts = enc.pts++;

    AVFrame *in = f;
    AVFrame *hw = NULL;
    if (enc.graph) {
        if (av_buffersrc_add_frame_flags(enc.src, f, AV_BUFFERSRC_FLAG_KEEP_REF) < 0) goto out;
        hw = av_frame_alloc();
        if (av_buffersink_get_frame(enc.sink, hw) < 0) goto out;
        in = hw;
    } else if (enc.sws) {
        av_frame_make_writable(enc.sw);
        sws_scale(enc.sws, (const uint8_t *const *)f->data, f->linesize, 0, enc.h, enc.sw->data, enc.sw->linesize);
        enc.sw->pts = f->pts;
        in = enc.sw;
    }
    if (enc.force_key) {
        in->pict_type = AV_PICTURE_TYPE_I;
        in->flags |= AV_FRAME_FLAG_KEY;
        enc.force_key = 0;
    } else {
        in->pict_type = AV_PICTURE_TYPE_NONE;
        in->flags &= ~AV_FRAME_FLAG_KEY;
    }
    if (avcodec_send_frame(enc.cc, in) < 0) goto out;
    r = drain(deliver);
out:
    av_frame_free(&hw);
    av_frame_free(&f);
    return r;
}

// ---------------------------------------------------------------- EVDI yakalama

static evdi_handle ev;
static struct evdi_buffer buf;
static int have_buf, update_pending, fresh, need_encoder;
static int frames_sent;

static void grab(void) {
    struct evdi_rect rects[16];
    int n = 16;
    evdi_grab_pixels(ev, rects, &n);
    update_pending = 0;
    fresh = 1;
}

static void request(void) {
    if (!have_buf || update_pending) return;
    if (evdi_request_update(ev, BUF_ID)) grab();
    else update_pending = 1;
}

static void on_mode(struct evdi_mode m, void *u) {
    (void)u;
    logi("kip: %dx%d@%d", m.width, m.height, m.refresh_rate);
    if (have_buf) { evdi_unregister_buffer(ev, BUF_ID); free(buf.buffer); have_buf = 0; }
    if (m.width <= 0 || m.height <= 0) return;
    buf.id = BUF_ID;
    buf.width = m.width;
    buf.height = m.height;
    buf.stride = m.width * 4;
    buf.buffer = calloc((size_t)buf.stride, m.height);
    buf.rects = NULL;
    buf.rect_count = 0;
    evdi_register_buffer(ev, buf);
    have_buf = 1;
    update_pending = 0;
    need_encoder = 1;
    status("#size %dx%d", m.width, m.height);
    request();
}

static void on_update(int id, void *u) { (void)u; (void)id; grab(); }

static int evdi_start(void) {
    int dev = -1;
    for (int pass = 0; pass < 2 && dev < 0; pass++) {
        for (int i = 0; i < 16; i++)
            if (evdi_check_device(i) == AVAILABLE) { dev = i; break; }
        if (dev < 0 && pass == 0 && evdi_add_device() <= 0) break;
    }
    if (dev < 0) {
        static int told;
        if (!told++)
            notify(access("/sys/devices/evdi", F_OK) == 0
                       ? "Sanal ekran cihazi yok. Bilgisayari yeniden baslatin ya da: sudo modprobe -r evdi && sudo modprobe evdi"
                       : "EVDI surucusu yuklu degil. Yukleyiciyi yeniden calistirin ya da: sudo modprobe evdi");
        return -1;
    }
    ev = evdi_open(dev);
    if (ev == EVDI_INVALID_HANDLE) { logi("evdi_open(card%d) basarisiz", dev); return -1; }
    unsigned char edid[128];
    make_edid(edid, opt.width, opt.height, opt.fps);
    evdi_connect2(ev, edid, sizeof edid, (uint32_t)opt.width * opt.height,
                  (uint32_t)opt.width * opt.height * (opt.fps + 1));
    logi("sanal ekran: card%d, %dx%d@%d", dev, opt.width, opt.height, opt.fps);
    return 0;
}

static void evdi_stop(void) {
    if (!ev) return;
    if (have_buf) { evdi_unregister_buffer(ev, BUF_ID); free(buf.buffer); have_buf = 0; }
    evdi_disconnect(ev);
    evdi_close(ev);
    ev = NULL;
}

// ---------------------------------------------------------------- ana dongu

static int listen_on(int port) {
    int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port),
                            .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};   // yalnizca USB (adb reverse)
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 2) < 0) {
        logi("127.0.0.1:%d dinlenemiyor: %s", port, strerror(errno));
        return -1;
    }
    return s;
}

static void on_sig(int s) { (void)s; stop = 1; }

static void usage(void) {
    fprintf(stderr, "kullanim: displaytube [--port N] [--size phone|WxH] [--bitrate bps] [--fps N]\n"
                    "                      [--encoder auto|vaapi|nvenc|x264] [--apk yol] [--no-adb]\n"
                    "          displaytube --check\n");
    exit(2);
}

// Kurulum denetimi. Satirlar "OK|UYARI|HATA <bilesen> <aciklama>"; yukleyici bunlari okur.
// Cikis kodu: 0 = calisir, 1 = zorunlu bilesen eksik.
static int check(void) {
    int bad = 0;
    quiet = 1;
    if (access("/sys/devices/evdi", F_OK) != 0) {
        printf("HATA evdi surucu yuklu degil (modprobe evdi)\n"); bad = 1;
    } else {
        glob_t g;
        int n = glob("/sys/devices/platform/evdi.*", 0, NULL, &g) == 0 ? (int)g.gl_pathc : 0;
        if (n) globfree(&g);
        if (n) printf("OK evdi %d sanal ekran cihazi\n", n);
        else { printf("HATA evdi surucu yuklu ama cihaz yok (initial_device_count=1)\n"); bad = 1; }
    }
    if (have_cmd("adb")) printf("OK adb bulundu\n");
    else { printf("HATA adb bulunamadi\n"); bad = 1; }
    if (access(opt.apk, R_OK) == 0) printf("OK apk %s\n", opt.apk);
    else printf("UYARI apk bulunamadi: %s (telefona elle kurulmali)\n", opt.apk);

    static const char *names[] = {"vaapi", "nvenc", "x264"};
    int w = 1280, h = 720, stride = w * 4, any = 0, hw = 0;
    unsigned char *black = calloc((size_t)stride, h);
    const char *saved = opt.encoder;
    for (int i = 0; i < 3; i++) {
        opt.encoder = names[i];
        if (enc_open(w, h, black, stride) == 0) {
            printf("OK kodlayici %s\n", names[i]);
            any = 1;
            if (i < 2) hw = 1;
        } else printf("-- kodlayici %s yok\n", names[i]);
        enc_close();
    }
    opt.encoder = saved;
    free(black);
    if (!any) { printf("HATA kodlayici hicbir H.264 kodlayici calismiyor\n"); bad = 1; }
    else if (!hw) printf("UYARI kodlayici donanim kodlayici yok, yazilim (x264) kullanilacak: gecikme ve CPU yuku artar\n");
    return bad;
}

int main(int argc, char **argv) {
    const char *size = "phone";
    int do_check = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--no-adb")) { opt.adb = 0; continue; }
        if (!strcmp(a, "--check")) { do_check = 1; continue; }
        if (i + 1 >= argc) usage();
        const char *v = argv[++i];
        if (!strcmp(a, "--port")) opt.port = atoi(v);
        else if (!strcmp(a, "--size")) size = v;
        else if (!strcmp(a, "--bitrate")) opt.bitrate = atoi(v);
        else if (!strcmp(a, "--fps")) opt.fps = atoi(v);
        else if (!strcmp(a, "--encoder")) opt.encoder = v;
        else if (!strcmp(a, "--apk")) opt.apk = v;
        else usage();
    }
    av_log_set_level(AV_LOG_QUIET);
    if (do_check) return check();
    if (!strcmp(size, "phone")) {
        if (phone_size(&opt.width, &opt.height) < 0) {
            logi("telefon boyutu okunamadi, 1920x1080 kullaniliyor");
            opt.width = 1920; opt.height = 1080;
        }
    } else if (sscanf(size, "%dx%d", &opt.width, &opt.height) != 2) usage();
    opt.width &= ~1;
    opt.height &= ~1;

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    signal(SIGPIPE, SIG_IGN);
    av_log_set_level(AV_LOG_ERROR);

    int ls = listen_on(opt.port);
    if (ls < 0) return 1;
    logi("dinleniyor: 127.0.0.1:%d", opt.port);
    pthread_t adb_thread;
    if (opt.adb) pthread_create(&adb_thread, NULL, adb_watch, NULL);

    double backoff = 0.5, last_send = 0, fps_t = now();
    int fps_n = 0;
    while (!stop) {
        if (!ev && evdi_start() < 0) {
            for (double t = now(); !stop && now() - t < backoff;) usleep(50000);
            backoff = backoff * 2 > 5 ? 5 : backoff * 2;
            continue;
        }
        backoff = 0.5;

        struct evdi_event_context ctx = {0};
        ctx.mode_changed_handler = on_mode;
        ctx.update_ready_handler = on_update;

        struct pollfd p[3] = {
            {.fd = evdi_get_event_ready(ev), .events = POLLIN},
            {.fd = ls, .events = POLLIN},
            {.fd = client, .events = POLLIN},
        };
        int timeout = IDLE_RESEND_MS;
        if (client >= 0 && have_buf) {
            int left = (int)((last_send + IDLE_RESEND_MS / 1000.0 - now()) * 1000);
            timeout = left < 0 ? 0 : left;
        }
        poll(p, client >= 0 ? 3 : 2, timeout);

        if (p[0].revents & POLLIN) evdi_handle_events(ev, &ctx);
        if (p[1].revents & POLLIN) {
            int c = accept4(ls, NULL, NULL, SOCK_CLOEXEC);
            if (c >= 0) {
                client_close();
                int one = 1;
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                struct timeval tv = {2, 0};      // takilan telefon ana donguyu kilitlemesin
                setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
                client = c;
                client_cfg_len = -1;
                need_encoder = 1;                // yeni istemci: ayar + IDR ile basla
                status("#client 1");
            }
        }
        if (client >= 0 && (p[2].revents & (POLLIN | POLLHUP | POLLERR))) {
            char tmp[256];
            if (recv(client, tmp, sizeof tmp, MSG_DONTWAIT) <= 0) client_close();
        }

        request();
        if (client < 0 || !have_buf) { fresh = 0; continue; }
        if (!fresh && now() - last_send < IDLE_RESEND_MS / 1000.0) continue;

        if (need_encoder || enc.w != buf.width || enc.h != buf.height) {
            if (enc_open(buf.width, buf.height, buf.buffer, buf.stride) < 0) {
                notify("Hicbir H.264 kodlayici acilamadi (VAAPI/NVENC/x264). Yukleyiciyi yeniden calistirin.");
                stop = 1;
                break;
            }
            need_encoder = 0;
            client_cfg_len = -1;
        }
        if (enc_frame(buf.buffer, buf.stride, 1) < 0) {
            logi("kodlama hatasi, kodlayici yeniden kuruluyor");
            need_encoder = 1;
            continue;
        }
        fresh = 0;
        last_send = now();
        frames_sent++;
        fps_n++;
        request();
        if (now() - fps_t >= 2) {
            status("#fps %.1f", fps_n / (now() - fps_t));
            fps_n = 0;
            fps_t = now();
        }
    }

    client_close();
    enc_close();
    evdi_stop();
    close(ls);
    if (opt.adb) pthread_join(adb_thread, NULL);
    return 0;
}
