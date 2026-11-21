// Monitor duzenini izler: hangi ekran masaustunde nerede (mantiksal koordinatlar).
// Mutlak fare cihazlarini bilesimciler (KWin, Mutter, wlroots, X sunucusu) tum masaustu alanina
// (butun ekranlari kapsayan dikdortgen) esler. Telefondaki bir noktayi sanal ekranin uzerine dusurmek
// icin sanal ekranin bu alan icindeki yerini bilmek gerekir.
//
// Wayland: standart xdg-output protokolu (her bilesimcide var), masaustu ortamindan bagimsiz.
// Ayri bir thread'de olaylari dinler; ekran eklenip tasininca bilgiler guncellenir.
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

#include "dt.h"
#include "xdg-output-protocol.h"

struct out {
    struct wl_output *wo;
    struct zxdg_output_v1 *xo;
    uint32_t gname;
    int x, y, w, h;
    char name[64];
    struct out *next;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct out *outs;
static struct zxdg_output_manager_v1 *manager;
static int started;

static void xo_pos(void *d, struct zxdg_output_v1 *x, int32_t px, int32_t py) {
    (void)x;
    struct out *o = d;
    pthread_mutex_lock(&lock);
    o->x = px; o->y = py;
    pthread_mutex_unlock(&lock);
}
static void xo_size(void *d, struct zxdg_output_v1 *x, int32_t w, int32_t h) {
    (void)x;
    struct out *o = d;
    pthread_mutex_lock(&lock);
    o->w = w; o->h = h;
    pthread_mutex_unlock(&lock);
}
static void xo_done(void *d, struct zxdg_output_v1 *x) { (void)d; (void)x; }
static void xo_name(void *d, struct zxdg_output_v1 *x, const char *name) {
    (void)x;
    struct out *o = d;
    pthread_mutex_lock(&lock);
    snprintf(o->name, sizeof o->name, "%s", name);
    pthread_mutex_unlock(&lock);
}
static void xo_desc(void *d, struct zxdg_output_v1 *x, const char *s) { (void)d; (void)x; (void)s; }

static const struct zxdg_output_v1_listener xo_listener = {xo_pos, xo_size, xo_done, xo_name, xo_desc};

static void watch(struct out *o) {
    if (o->xo || !manager) return;
    o->xo = zxdg_output_manager_v1_get_xdg_output(manager, o->wo);
    zxdg_output_v1_add_listener(o->xo, &xo_listener, o);
}

static void reg_global(void *d, struct wl_registry *r, uint32_t gname, const char *iface, uint32_t ver) {
    (void)d;
    if (!strcmp(iface, wl_output_interface.name)) {
        struct out *o = calloc(1, sizeof *o);
        o->gname = gname;
        o->wo = wl_registry_bind(r, gname, &wl_output_interface, 1);
        pthread_mutex_lock(&lock);
        o->next = outs;
        outs = o;
        pthread_mutex_unlock(&lock);
        watch(o);
    } else if (!strcmp(iface, zxdg_output_manager_v1_interface.name) && ver >= 2) {   // v2: ad (name) olayi
        manager = wl_registry_bind(r, gname, &zxdg_output_manager_v1_interface, ver < 3 ? ver : 3);
        for (struct out *o = outs; o; o = o->next) watch(o);
    }
}

static void reg_remove(void *d, struct wl_registry *r, uint32_t gname) {
    (void)d; (void)r;
    pthread_mutex_lock(&lock);
    for (struct out **p = &outs; *p; p = &(*p)->next) {
        if ((*p)->gname != gname) continue;
        struct out *o = *p;
        *p = o->next;
        if (o->xo) zxdg_output_v1_destroy(o->xo);
        wl_output_destroy(o->wo);
        free(o);
        break;
    }
    pthread_mutex_unlock(&lock);
}

static const struct wl_registry_listener reg_listener = {reg_global, reg_remove};

static void forget_all(void) {
    pthread_mutex_lock(&lock);
    while (outs) {
        struct out *o = outs;
        outs = o->next;
        free(o);   // baglanti kapandi; nesneler onunla birlikte gitti
    }
    pthread_mutex_unlock(&lock);
    manager = NULL;
}

static void *run(void *arg) {
    (void)arg;
    int told = 0;
    for (;;) {
        struct wl_display *dpy = wl_display_connect(NULL);   // WAYLAND_DISPLAY, yoksa wayland-0
        if (!dpy) {
            if (!told++) logi("monitor duzeni: Wayland oturumu bulunamadi (fare kipi X11'de henuz desteklenmiyor)");
            sleep(5);
            continue;
        }
        told = 0;
        struct wl_registry *reg = wl_display_get_registry(dpy);
        wl_registry_add_listener(reg, &reg_listener, NULL);
        wl_display_roundtrip(dpy);
        wl_display_roundtrip(dpy);
        if (!manager) logi("monitor duzeni: bilesimci xdg-output desteklemiyor");
        while (wl_display_dispatch(dpy) != -1) { }
        logi("monitor duzeni: Wayland baglantisi koptu, yeniden deneniyor");
        forget_all();
        wl_display_disconnect(dpy);
        sleep(2);
    }
    return NULL;
}

void layout_start(void) {
    if (started) return;
    started = 1;
    pthread_t t;
    if (pthread_create(&t, NULL, run, NULL) == 0) pthread_detach(t);
}

// Telefondaki nokta (0..65535) -> tum masaustu alanina gore mutlak fare degeri (0..65535).
int layout_map(const char *output, int fx, int fy, int *ax, int *ay) {
    int ok = -1;
    pthread_mutex_lock(&lock);
    int bx0 = 0, by0 = 0, bx1 = 0, by1 = 0, first = 1;
    struct out *t = NULL;
    for (struct out *o = outs; o; o = o->next) {
        if (o->w <= 0 || o->h <= 0) continue;
        if (first || o->x < bx0) bx0 = o->x;
        if (first || o->y < by0) by0 = o->y;
        if (first || o->x + o->w > bx1) bx1 = o->x + o->w;
        if (first || o->y + o->h > by1) by1 = o->y + o->h;
        first = 0;
        if (output && !strcmp(o->name, output)) t = o;
    }
    if (t && bx1 > bx0 && by1 > by0) {
        double px = t->x + fx / 65535.0 * (t->w - 1) + 0.5;
        double py = t->y + fy / 65535.0 * (t->h - 1) + 0.5;
        *ax = (int)((px - bx0) * 65535.0 / (bx1 - bx0));
        *ay = (int)((py - by0) * 65535.0 / (by1 - by0));
        ok = 0;
    }
    pthread_mutex_unlock(&lock);
    return ok;
}
