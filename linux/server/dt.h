// DisplayTube Linux sunucusu: dosyalar arasi ortak bildirimler
#pragma once

void logi(const char *fmt, ...);
void notify(const char *msg);

// touch.c: /dev/uinput ile cok parmakli dokunmatik ekran (docs/PROTOKOL.md, TOUCH paketi)
int touch_available(void);                                  // /dev/uinput yazilabilir mi
int touch_open(int width, int height, const char *output);  // output: DRM baglayici adi (WL_OUTPUT icin), NULL olabilir
void touch_packet(const unsigned char *p, int len);         // TOUCH paketinin yuku
void touch_close(void);

// mouse.c: fare kipi (MOUSE paketi); layout.c: monitor duzeni (xdg-output)
int mouse_open(const char *output);
void mouse_packet(const unsigned char *p, int len);
void mouse_close(void);
void layout_start(void);
int layout_map(const char *output, int fx, int fy, int *ax, int *ay);

// audio.c: PipeWire/PulseAudio'dan ses yakalama
enum { AUDIO_OFF = 0, AUDIO_SINK = 1, AUDIO_MIRROR = 2 };
#define AUDIO_RATE 48000
#define AUDIO_CHANNELS 2
#define AUDIO_CHUNK (AUDIO_RATE / 100 * AUDIO_CHANNELS * 2)   // 10 ms, s16le
int audio_start(int mode, int out_fd);   // out_fd'ye AUDIO_CHUNK baytlik parcalar yazar (bloklamayan boru)
void audio_stop(void);
