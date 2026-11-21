// Fare kipi: telefon hareketleri kendisi yorumlar (dokun = sol tik, basili tut = sag tik,
// surukle, iki parmakla kaydir) ve MOUSE paketleri gonderir. Burada /dev/uinput ile mutlak
// konumlu bir fare cihazi olusturulur; nokta layout.c ile sanal ekranin uzerine dusurulur.
// Masaustu ayari gerektirmez.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "dt.h"

#define DEVICE_NAME "DTB DisplayTube Mouse"

static int fd = -1;
static char output[64];
static int buttons;              // son durum: 1 sol, 2 sag, 4 orta
static int wheel_acc, hwheel_acc;
static int told;

static void emit(int type, int code, int value) {
    struct input_event e;
    memset(&e, 0, sizeof e);
    e.type = (unsigned short)type;
    e.code = (unsigned short)code;
    e.value = value;
    if (write(fd, &e, sizeof e) < 0 && errno != EAGAIN) logi("uinput yazilamadi: %s", strerror(errno));
}

static int abs_setup(int code) {
    struct uinput_abs_setup a;
    memset(&a, 0, sizeof a);
    a.code = (unsigned short)code;
    a.absinfo.maximum = 65535;
    return ioctl(fd, UI_ABS_SETUP, &a);
}

int mouse_open(const char *out) {
    mouse_close();
    snprintf(output, sizeof output, "%s", out ? out : "");
    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        logi("fare kipi kapali: /dev/uinput acilamadi (%s)", strerror(errno));
        return -1;
    }
    int bad = 0;
    bad |= ioctl(fd, UI_SET_EVBIT, EV_KEY);
    bad |= ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    bad |= ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT);
    bad |= ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE);
    bad |= ioctl(fd, UI_SET_EVBIT, EV_REL);
    bad |= ioctl(fd, UI_SET_RELBIT, REL_WHEEL);
    bad |= ioctl(fd, UI_SET_RELBIT, REL_HWHEEL);
    bad |= ioctl(fd, UI_SET_RELBIT, REL_WHEEL_HI_RES);
    bad |= ioctl(fd, UI_SET_RELBIT, REL_HWHEEL_HI_RES);
    bad |= ioctl(fd, UI_SET_EVBIT, EV_ABS);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_X);
    bad |= ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    bad |= abs_setup(ABS_X);
    bad |= abs_setup(ABS_Y);

    struct uinput_setup s;
    memset(&s, 0, sizeof s);
    s.id.bustype = BUS_VIRTUAL;
    s.id.vendor = 0x1209;
    s.id.product = 0xd7bf;
    s.id.version = 1;
    snprintf(s.name, sizeof s.name, "%s", DEVICE_NAME);
    bad |= ioctl(fd, UI_DEV_SETUP, &s);
    bad |= ioctl(fd, UI_DEV_CREATE);
    if (bad) {
        logi("fare kipi kapali: uinput cihazi kurulamadi (%s)", strerror(errno));
        close(fd);
        fd = -1;
        return -1;
    }
    buttons = wheel_acc = hwheel_acc = told = 0;
    logi("fare kipi: ekran %s", *output ? output : "(bilinmiyor)");
    return 0;
}

static void wheel(int hi, int *acc, int code_hi, int code) {
    if (!hi) return;
    emit(EV_REL, code_hi, hi);
    *acc += hi;
    int notches = *acc / 120;          // eski uygulamalar icin tam centik
    if (notches) {
        emit(EV_REL, code, notches);
        *acc -= notches * 120;
    }
}

// Yuk: u8 dugmeler, u16 x, u16 y, i16 dikey tekerlek, i16 yatay tekerlek (1/120 centik)
void mouse_packet(const unsigned char *p, int len) {
    if (fd < 0 || len < 9) return;
    int b = p[0] & 7;
    int fx = (p[1] << 8) | p[2], fy = (p[3] << 8) | p[4];
    int wv = (short)((p[5] << 8) | p[6]), wh = (short)((p[7] << 8) | p[8]);
    int ax, ay;
    if (layout_map(output, fx, fy, &ax, &ay) == 0) {
        emit(EV_ABS, ABS_X, ax);
        emit(EV_ABS, ABS_Y, ay);
    } else {
        // Yer bilinmiyorsa imlec nerede ise oraya tiklamak tehlikeli: yalnizca birak, basma.
        if (!told++) logi("fare kipi: sanal ekranin (%s) masaustundeki yeri bilinmiyor, tiklamalar yok sayiliyor", output);
        b = 0;
        wv = wh = 0;
    }
    // Once konum, sonra dugme: tik dogru yere gitsin
    emit(EV_SYN, SYN_REPORT, 0);
    static const int codes[3] = {BTN_LEFT, BTN_RIGHT, BTN_MIDDLE};
    int changed = 0;
    for (int i = 0; i < 3; i++)
        if ((b ^ buttons) & (1 << i)) { emit(EV_KEY, codes[i], (b >> i) & 1); changed = 1; }
    buttons = b;
    wheel(wv, &wheel_acc, REL_WHEEL_HI_RES, REL_WHEEL);
    wheel(wh, &hwheel_acc, REL_HWHEEL_HI_RES, REL_HWHEEL);
    if (changed || wv || wh) emit(EV_SYN, SYN_REPORT, 0);
}

void mouse_close(void) {
    if (fd < 0) return;
    if (buttons) {   // basili dugme kalmasin
        static const int codes[3] = {BTN_LEFT, BTN_RIGHT, BTN_MIDDLE};
        for (int i = 0; i < 3; i++)
            if (buttons & (1 << i)) emit(EV_KEY, codes[i], 0);
        emit(EV_SYN, SYN_REPORT, 0);
        buttons = 0;
    }
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    fd = -1;
}
