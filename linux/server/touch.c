// Telefondan gelen dokunuslari /dev/uinput ile cok parmakli dokunmatik ekran olarak verir
// (Linux MT protokolu B). Masaustu ortamindan bagimsizdir: X11 ve Wayland ayni cihazi gorur.
//
// Ekran eslemesi: cihazin 'phys' alani sanal ekranin DRM baglayici adidir (or. DVI-I-1).
// Yukleyicinin kurdugu udev kurali (70-displaytube.rules) bunu WL_OUTPUT ozelligine kopyalar;
// libinput_device_get_output_name() ile bunu okuyan bilesimciler (KWin, Weston, ...) dokunmatigi
// o ekrana esler. Cihaz adindaki "DTB" ve "DisplayTube", EDID'deki uretici/urun adiyla ayni oldugundan
// EDID adina gore esleyen bilesimciler (GNOME/Mutter) de dogru ekrani bulur.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "dt.h"

#define SLOTS 10
#define DEVICE_NAME "DTB DisplayTube Touchscreen"

static int fd = -1;
static int width, height;
static int slot_id[SLOTS];       // slottaki parmagin telefon no'su, -1 = bos
static int slot_x[SLOTS], slot_y[SLOTS];
static int next_tracking = 1;

int touch_available(void) {
    return access("/dev/uinput", W_OK) == 0;
}

static void emit(int type, int code, int value) {
    struct input_event e;
    memset(&e, 0, sizeof e);
    e.type = (unsigned short)type;
    e.code = (unsigned short)code;
    e.value = value;
    if (write(fd, &e, sizeof e) < 0 && errno != EAGAIN) logi("uinput yazilamadi: %s", strerror(errno));
}

static int abs_setup(int code, int max, int res) {
    struct uinput_abs_setup a;
    memset(&a, 0, sizeof a);
    a.code = (unsigned short)code;
    a.absinfo.minimum = 0;
    a.absinfo.maximum = max;
    a.absinfo.resolution = res;
    return ioctl(fd, UI_ABS_SETUP, &a);
}

int touch_open(int w, int h, const char *output) {
    touch_close();
    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        logi("dokunmatik kapali: /dev/uinput acilamadi (%s). Yukleyiciyi yeniden calistirin.", strerror(errno));
        return -1;
    }
    width = w;
    height = h;
    // EDID'deki fiziksel boyutla (150 x 70 mm) uyumlu cozunurluk (birim/mm)
    int xres = w / 150 > 0 ? w / 150 : 1, yres = h / 70 > 0 ? h / 70 : 1;

    int bad = 0;
    bad |= ioctl(fd, UI_SET_EVBIT, EV_KEY);
    bad |= ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
    bad |= ioctl(fd, UI_SET_EVBIT, EV_ABS);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_X);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_MT_SLOT);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_X);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y);
    bad |= ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);   // dokunmatik ekran (touchpad degil)
    bad |= abs_setup(ABS_X, w - 1, xres);
    bad |= abs_setup(ABS_Y, h - 1, yres);
    bad |= abs_setup(ABS_MT_SLOT, SLOTS - 1, 0);
    bad |= abs_setup(ABS_MT_TRACKING_ID, 65535, 0);
    bad |= abs_setup(ABS_MT_POSITION_X, w - 1, xres);
    bad |= abs_setup(ABS_MT_POSITION_Y, h - 1, yres);
    if (output && *output) bad |= ioctl(fd, UI_SET_PHYS, output);

    struct uinput_setup s;
    memset(&s, 0, sizeof s);
    s.id.bustype = BUS_VIRTUAL;
    s.id.vendor = 0x1209;    // pid.codes (acik kaynak projeler)
    s.id.product = 0xd7be;
    s.id.version = 1;
    snprintf(s.name, sizeof s.name, "%s", DEVICE_NAME);
    bad |= ioctl(fd, UI_DEV_SETUP, &s);
    bad |= ioctl(fd, UI_DEV_CREATE);
    if (bad) {
        logi("dokunmatik kapali: uinput cihazi kurulamadi (%s)", strerror(errno));
        close(fd);
        fd = -1;
        return -1;
    }
    for (int i = 0; i < SLOTS; i++) slot_id[i] = -1;
    logi("dokunmatik: %dx%d, ekran %s", w, h, output && *output ? output : "(bilinmiyor)");
    return 0;
}

static int find_slot(int id) {
    for (int i = 0; i < SLOTS; i++)
        if (slot_id[i] == id) return i;
    return -1;
}

static void release_slot(int s) {
    emit(EV_ABS, ABS_MT_SLOT, s);
    emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
    slot_id[s] = -1;
}

static void sync_frame(void) {
    int first = -1;
    for (int i = 0; i < SLOTS && first < 0; i++)
        if (slot_id[i] >= 0) first = i;
    emit(EV_KEY, BTN_TOUCH, first >= 0);
    if (first >= 0) {   // tek dokunus emulasyonu (eski istemciler icin)
        emit(EV_ABS, ABS_X, slot_x[first]);
        emit(EV_ABS, ABS_Y, slot_y[first]);
    }
    emit(EV_SYN, SYN_REPORT, 0);
}

void touch_packet(const unsigned char *p, int len) {
    if (fd < 0 || len < 1) return;
    int n = p[0];
    if (len < 1 + n * 6) return;
    for (int i = 0; i < n; i++) {
        const unsigned char *q = p + 1 + i * 6;
        int id = q[0], down = q[1];
        int x = (int)(((long)((q[2] << 8) | q[3]) * (width - 1) + 32767) / 65535);
        int y = (int)(((long)((q[4] << 8) | q[5]) * (height - 1) + 32767) / 65535);
        int s = find_slot(id);
        if (!down) {
            if (s >= 0) release_slot(s);
            continue;
        }
        if (s < 0) {
            s = find_slot(-1);
            if (s < 0) continue;   // 10'dan fazla parmak
            slot_id[s] = id;
            emit(EV_ABS, ABS_MT_SLOT, s);
            emit(EV_ABS, ABS_MT_TRACKING_ID, next_tracking++ & 0xffff);
        } else {
            emit(EV_ABS, ABS_MT_SLOT, s);
        }
        slot_x[s] = x;
        slot_y[s] = y;
        emit(EV_ABS, ABS_MT_POSITION_X, x);
        emit(EV_ABS, ABS_MT_POSITION_Y, y);
    }
    sync_frame();
}

void touch_close(void) {
    if (fd < 0) return;
    // Basili kalan parmak birakilmasin (telefon kopunca ekranda "takili dokunus" olmasin)
    int any = 0;
    for (int i = 0; i < SLOTS; i++)
        if (slot_id[i] >= 0) { release_slot(i); any = 1; }
    if (any) sync_frame();
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    fd = -1;
}
