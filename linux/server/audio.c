// Bilgisayar sesini telefona gonderir. PulseAudio API'si kullanilir; PipeWire (pipewire-pulse)
// ve PulseAudio'da aynen calisir, masaustu ortamindan bagimsizdir.
//
//   AUDIO_SINK   : telefon bagliyken "DisplayTube" adli sanal ses cikisi acilir (HDMI monitorun
//                  hoparlorleri gibi). Bir uygulamayi ya da tum sesi ses ayarlarindan oraya yonlendirin.
//   AUDIO_MIRROR : varsayilan cikisin kopyasi telefona da gider (bilgisayar hoparlorleri de calar).
//
// Ses ayri bir thread'de 10 ms'lik parcalar halinde okunur ve bir boruya yazilir; ana dongu
// bunlari AUDIO paketi olarak gonderir (sokete tek yazar ana donguyle kalir).
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <pulse/pulseaudio.h>
#include <pulse/simple.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "dt.h"

#define SINK_NAME "displaytube"

static pthread_t thread;
static int thread_on;
static volatile int running;
static int mode, out_fd;

// ------------------------------------------------- sanal cikis (module-null-sink)

static pa_mainloop *ml;
static pa_context *ctx;
static uint32_t module_idx = PA_INVALID_INDEX;

static int pulse_connect(void) {
    ml = pa_mainloop_new();
    ctx = pa_context_new(pa_mainloop_get_api(ml), "DisplayTube");
    if (pa_context_connect(ctx, NULL, PA_CONTEXT_NOAUTOSPAWN, NULL) < 0) return -1;
    for (;;) {
        pa_context_state_t st = pa_context_get_state(ctx);
        if (st == PA_CONTEXT_READY) return 0;
        if (!PA_CONTEXT_IS_GOOD(st)) return -1;
        pa_mainloop_iterate(ml, 1, NULL);
    }
}

static void pulse_disconnect(void) {
    if (ctx) { pa_context_disconnect(ctx); pa_context_unref(ctx); ctx = NULL; }
    if (ml) { pa_mainloop_free(ml); ml = NULL; }
}

static void wait_op(pa_operation *o) {
    if (!o) return;
    while (pa_operation_get_state(o) == PA_OPERATION_RUNNING) pa_mainloop_iterate(ml, 1, NULL);
    pa_operation_unref(o);
}

static void on_index(pa_context *c, uint32_t idx, void *u) { (void)c; *(uint32_t *)u = idx; }
static void on_success(pa_context *c, int ok, void *u) { (void)c; (void)ok; (void)u; }

static void on_sink(pa_context *c, const pa_sink_info *i, int eol, void *u) {
    (void)c;
    if (!eol && i) *(uint32_t *)u = i->owner_module;
}

static int sink_create(void) {
    // Onceki calismadan (cokme vb.) kalan cikis varsa kaldir
    uint32_t old = PA_INVALID_INDEX;
    wait_op(pa_context_get_sink_info_by_name(ctx, SINK_NAME, on_sink, &old));
    if (old != PA_INVALID_INDEX) wait_op(pa_context_unload_module(ctx, old, on_success, NULL));

    char args[256];
    snprintf(args, sizeof args,
             "sink_name=" SINK_NAME " sink_properties=device.description=DisplayTube "
             "rate=%d channels=%d format=s16le",
             AUDIO_RATE, AUDIO_CHANNELS);
    module_idx = PA_INVALID_INDEX;
    wait_op(pa_context_load_module(ctx, "module-null-sink", args, on_index, &module_idx));
    if (module_idx == PA_INVALID_INDEX) return -1;
    logi("ses: 'DisplayTube' ses cikisi acildi (ses ayarlarindan secin)");
    return 0;
}

static void sink_remove(void) {
    if (module_idx == PA_INVALID_INDEX || !ctx) return;
    wait_op(pa_context_unload_module(ctx, module_idx, on_success, NULL));
    module_idx = PA_INVALID_INDEX;
}

// ------------------------------------------------- yakalama thread'i

static void *capture(void *arg) {
    (void)arg;
    if (pulse_connect() < 0) {
        logi("ses kapali: PipeWire/PulseAudio'ya baglanilamadi");
        pulse_disconnect();
        return NULL;
    }
    const char *dev = "@DEFAULT_MONITOR@";
    if (mode == AUDIO_SINK) {
        if (sink_create() < 0) {
            logi("ses kapali: sanal ses cikisi acilamadi (module-null-sink)");
            pulse_disconnect();
            return NULL;
        }
        dev = SINK_NAME ".monitor";
    }

    pa_sample_spec spec = {.format = PA_SAMPLE_S16LE, .rate = AUDIO_RATE, .channels = AUDIO_CHANNELS};
    pa_buffer_attr attr = {.maxlength = (uint32_t)-1, .tlength = (uint32_t)-1, .prebuf = (uint32_t)-1,
                           .minreq = (uint32_t)-1, .fragsize = AUDIO_CHUNK};   // dusuk gecikme: 10 ms parca
    int err = 0;
    pa_simple *s = pa_simple_new(NULL, "DisplayTube", PA_STREAM_RECORD, dev, "Telefona ses", &spec, NULL, &attr, &err);
    if (!s) {
        logi("ses kapali: %s okunamadi (%s)", dev, pa_strerror(err));
    } else {
        logi("ses: %s -> telefon (%d Hz, %d kanal)", dev, AUDIO_RATE, AUDIO_CHANNELS);
        unsigned char chunk[AUDIO_CHUNK];
        while (running) {
            if (pa_simple_read(s, chunk, sizeof chunk, &err) < 0) {
                logi("ses okunamadi: %s", pa_strerror(err));
                break;
            }
            // Boru doluysa (ana dongu mesgul) parcayi at: gecikme birikmesin
            if (write(out_fd, chunk, sizeof chunk) < 0 && errno != EAGAIN) break;
        }
        pa_simple_free(s);
    }
    sink_remove();
    pulse_disconnect();
    return NULL;
}

int audio_start(int m, int fd) {
    audio_stop();
    if (m == AUDIO_OFF) return -1;
    mode = m;
    out_fd = fd;
    running = 1;
    if (pthread_create(&thread, NULL, capture, NULL) != 0) { running = 0; return -1; }
    thread_on = 1;
    return 0;
}

void audio_stop(void) {
    if (!thread_on) return;
    running = 0;
    pthread_join(thread, NULL);   // pa_simple_read en gec ~10 ms'de doner
    thread_on = 0;
}
