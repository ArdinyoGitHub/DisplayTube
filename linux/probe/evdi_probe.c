// evdi_probe: EVDI sanal ekranini acar, kareleri sayar, bir kareyi PPM olarak yazar.
// Derleme: cc -O2 -o evdi_probe evdi_probe.c -levdi
// Kullanim: evdi_probe [genislik yukseklik saniye cikti.ppm]
#include <evdi_lib.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define BUF_ID 1

static volatile sig_atomic_t stop;
static evdi_handle h;
static struct evdi_mode mode;
static struct evdi_buffer buf;
static int have_buf, frames, dirty_total;
static const char *out_path = "evdi_frame.ppm";
static int saved;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// 1 ekranlik EDID 1.3: tek detayli zamanlama (CVT-RB benzeri), isim "DisplayTube".
static void make_edid(unsigned char e[128], int w, int hgt, int hz) {
    memset(e, 0, 128);
    const unsigned char hdr[8] = {0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0};
    memcpy(e, hdr, 8);
    // Uretici "DTB": 5'er bit harf
    unsigned short m = ((('D' - '@') & 31) << 10) | ((('T' - '@') & 31) << 5) | (('B' - '@') & 31);
    e[8] = m >> 8; e[9] = m & 0xff;
    e[10] = 0x01; e[11] = 0x00;           // urun kodu
    e[12] = 1;                             // seri
    e[16] = 1; e[17] = 2026 - 1990;        // hafta, yil
    e[18] = 1; e[19] = 3;                  // EDID 1.3
    e[20] = 0x80;                          // dijital giris
    e[21] = 15; e[22] = 7;                 // boyut (cm), kabaca telefon
    e[23] = 0x78;                          // gamma 2.2
    e[24] = 0x0a;                          // RGB, tercih edilen zamanlama ilk DTD
    const unsigned char chroma[10] = {0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54};
    memcpy(e + 25, chroma, 10);
    for (int i = 38; i < 54; i++) e[i] = 0x01;  // standart zamanlamalar bos

    // CVT reduced blanking: hblank 160 (on 48, senk 32, arka 80), dikey on 3, senk 6
    int hfp = 48, hs = 32, hbp = 80, htot = w + hfp + hs + hbp;
    double line_us = (1e6 / hz - 460.0) / hgt;
    int vbl = (int)(460.0 / line_us) + 1;
    if (vbl < 3 + 6 + 6) vbl = 3 + 6 + 6;
    int vfp = 3, vs = 6, vtot = hgt + vbl;
    long clk10k = ((long)htot * vtot * hz + 9999) / 10000;  // 10 kHz birim
    clk10k = (clk10k + 24) / 25 * 25;                      // 250 kHz'e yuvarla
    int hbl = htot - w;
    unsigned char *d = e + 54;
    d[0] = clk10k & 0xff; d[1] = clk10k >> 8;
    d[2] = w & 0xff; d[3] = hbl & 0xff; d[4] = ((w >> 8) << 4) | (hbl >> 8);
    d[5] = hgt & 0xff; d[6] = vbl & 0xff; d[7] = ((hgt >> 8) << 4) | (vbl >> 8);
    d[8] = hfp & 0xff; d[9] = hs & 0xff;
    d[10] = ((vfp & 15) << 4) | (vs & 15);
    d[11] = ((hfp >> 8) << 6) | ((hs >> 8) << 4) | ((vfp >> 4) << 2) | (vs >> 4);
    d[12] = 150 & 0xff; d[13] = 70; d[14] = 0;  // mm
    d[17] = 0x1a;                                // dijital ayri senk, +h -v

    // Isim tanimlayicisi
    d = e + 72;
    d[3] = 0xfc;
    const char *name = "DisplayTube\n ";
    memcpy(d + 5, name, 13);
    // Aralik sinirlari
    d = e + 90;
    d[3] = 0xfd; d[5] = 24; d[6] = 75; d[7] = 30; d[8] = 160;
    d[9] = (unsigned char)(clk10k / 1000 + 1); d[10] = 0; d[11] = 0x0a;
    memset(d + 12, 0x20, 6);
    // Bos tanimlayici
    e[108 + 3] = 0x10;

    unsigned sum = 0;
    for (int i = 0; i < 127; i++) sum += e[i];
    e[127] = (unsigned char)(256 - (sum & 0xff));
}

static void save_ppm(void) {
    FILE *f = fopen(out_path, "wb");
    if (!f) { perror(out_path); return; }
    fprintf(f, "P6\n%d %d\n255\n", buf.width, buf.height);
    unsigned char *row = malloc(buf.width * 3);
    for (int y = 0; y < buf.height; y++) {
        const unsigned char *src = (const unsigned char *)buf.buffer + (size_t)y * buf.stride;
        for (int x = 0; x < buf.width; x++) {  // BGRA (XRGB8888, little-endian)
            row[x * 3 + 0] = src[x * 4 + 2];
            row[x * 3 + 1] = src[x * 4 + 1];
            row[x * 3 + 2] = src[x * 4 + 0];
        }
        fwrite(row, 1, buf.width * 3, f);
    }
    free(row);
    fclose(f);
    printf("kare kaydedildi: %s (%dx%d, stride %d)\n", out_path, buf.width, buf.height, buf.stride);
}

static void grab(void) {
    struct evdi_rect rects[16];
    int n = 16;
    evdi_grab_pixels(h, rects, &n);
    frames++;
    dirty_total += n;
    if (!saved && frames >= 30) { save_ppm(); saved = 1; }
}

static void request(void) {
    if (have_buf && evdi_request_update(h, BUF_ID)) grab();
}

static void on_mode(struct evdi_mode m, void *u) {
    (void)u;
    printf("kip: %dx%d@%d bpp %d format 0x%08x\n", m.width, m.height, m.refresh_rate,
           m.bits_per_pixel, m.pixel_format);
    if (have_buf) { evdi_unregister_buffer(h, BUF_ID); free(buf.buffer); have_buf = 0; }
    mode = m;
    buf.id = BUF_ID;
    buf.width = m.width;
    buf.height = m.height;
    buf.stride = m.width * 4;
    buf.buffer = calloc((size_t)buf.stride, m.height);
    buf.rects = NULL;
    buf.rect_count = 0;
    evdi_register_buffer(h, buf);
    have_buf = 1;
    request();
}

static void on_update(int id, void *u) { (void)u; (void)id; grab(); }
static void on_dpms(int m, void *u) { (void)u; printf("dpms: %d\n", m); }
static void on_crtc(int s, void *u) { (void)u; printf("crtc durumu: %d\n", s); }
static void on_sig(int s) { (void)s; stop = 1; }

int main(int argc, char **argv) {
    int w = argc > 2 ? atoi(argv[1]) : 1920;
    int hh = argc > 2 ? atoi(argv[2]) : 1080;
    int secs = argc > 3 ? atoi(argv[3]) : 10;
    if (argc > 4) out_path = argv[4];
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    int dev = -1;
    for (int i = 0; i < 16; i++)
        if (evdi_check_device(i) == AVAILABLE) { dev = i; break; }
    if (dev < 0) { fprintf(stderr, "bos evdi cihazi yok (echo 1 > /sys/devices/evdi/add)\n"); return 1; }
    h = evdi_open(dev);
    if (h == EVDI_INVALID_HANDLE) { fprintf(stderr, "evdi_open(%d) basarisiz\n", dev); return 1; }
    printf("evdi cihazi: card%d\n", dev);

    unsigned char edid[128];
    make_edid(edid, w, hh, 60);
    evdi_connect2(h, edid, sizeof edid, (uint32_t)w * hh, (uint32_t)w * hh * 61);

    struct evdi_event_context ctx = {0};
    ctx.mode_changed_handler = on_mode;
    ctx.update_ready_handler = on_update;
    ctx.dpms_handler = on_dpms;
    ctx.crtc_state_handler = on_crtc;

    struct pollfd p = {.fd = evdi_get_event_ready(h), .events = POLLIN};
    double t0 = now(), tlast = t0;
    int flast = 0;
    while (!stop && now() - t0 < secs) {
        if (poll(&p, 1, 20) > 0) evdi_handle_events(h, &ctx);
        request();
        double t = now();
        if (t - tlast >= 1.0) {
            printf("fps %.1f  (kirli bolge toplam %d)\n", (frames - flast) / (t - tlast), dirty_total);
            flast = frames; tlast = t;
        }
    }
    if (have_buf) evdi_unregister_buffer(h, BUF_ID);
    evdi_disconnect(h);
    evdi_close(h);
    printf("toplam kare: %d\n", frames);
    return 0;
}
