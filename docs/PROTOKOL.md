# DisplayTube kablo protokolü (v1: görüntü + fare/dokunmatik + ses)

Telefon, `adb reverse tcp:27183 tcp:27183` ile bilgisayardaki sunucuya **tek TCP bağlantısı** açar.
Her iki yönde de paket biçimi aynıdır:

```
[tür: 1 bayt][uzunluk: 4 bayt, big-endian][yük: uzunluk bayt]
```

Tüm çok baytlı sayılar **big-endian**'dır (PCM ses verisi hariç: o little-endian).

## Bilgisayar → telefon

| Tür | Ad | Yük |
|-----|----|-----|
| 1 | VIDEO_CONFIG | SPS+PPS, Annex-B. Değişirse telefon decoder'ı yeniden kurar. |
| 2 | VIDEO_KEY | Anahtar kare (IDR), Annex-B. Her paket tam bir kare. |
| 3 | VIDEO_FRAME | Kare, Annex-B. |
| 4 | SERVER_HELLO | `u16 sürüm` `u32 yetenekler` — yalnızca telefondan HELLO gelince gönderilir. |
| 5 | AUDIO_CONFIG | `u32 örnekleme hızı` `u8 kanal` `u8 biçim` (1 = PCM s16le). AUDIO'dan önce gelir. |
| 6 | AUDIO | Ham PCM (AUDIO_CONFIG biçiminde), ~10 ms'lik parçalar. |

## Telefon → bilgisayar

| Tür | Ad | Yük |
|-----|----|-----|
| 0x80 | HELLO | `u16 sürüm` `u32 yetenekler` `u16 ekran genişliği` `u16 ekran yüksekliği` — bağlanınca bir kez. |
| 0x81 | TOUCH | `u8 n`, ardından n kez: `u8 parmak no` `u8 basılı (1/0)` `u16 x` `u16 y` |
| 0x82 | MOUSE | `u8 düğmeler` `u16 x` `u16 y` `i16 dikey tekerlek` `i16 yatay tekerlek` |

- TOUCH koordinatları görüntü alanına göre **0..65535** arasıdır (0,0 sol üst; 65535,65535 sağ alt).
- Her TOUCH paketi o anda ekrandaki **bütün parmakları** içerir. Kalkan parmak bir kez `basılı=0` ile gelir
  (hareket iptal edilirse bütün parmaklar `basılı=0` gelir). Sunucu durumsuz uygulayabilir:
  pakette `basılı=1` olan parmaklar ekranda, `basılı=0` olanlar kalktı.
- Parmak no 0..9 arasıdır (Android pointer id).
- MOUSE **durum** gönderir: düğmeler o anda basılı olanlardır (bit 0 sol, bit 1 sağ, bit 2 orta). Sunucu
  önceki durumla karşılaştırıp bas/bırak üretir, **önce konumu** uygular sonra düğmeyi. x/y TOUCH gibi 0..65535.
  Tekerlek 1/120 çentik biriminde (Windows `WHEEL_DELTA` ile aynı); pozitif dikey = yukarı, pozitif yatay = sağa.
- Fare kipinde hareketleri **telefon** yorumlar: dokun = sol tık, basılı tut = sağ tık, sürükle = sol tuş basılı
  sürükleme, iki parmakla kaydır = tekerlek (doğal yön), iki parmakla dokun = sağ tık. Sunucu yalnızca uygular.

## Yetenek bitleri (`u32`)

| Bit | Anlam |
|-----|-------|
| 0x1 | TOUCH — telefon dokunuş gönderebilir / sunucu dokunuşu uygular |
| 0x2 | AUDIO — telefon sesi çalabilir / sunucu ses gönderir |
| 0x4 | MOUSE — telefon fare kipini bilir / sunucu fare kipini seçti (MOUSE paketleri gönderilir) |

Sunucu TOUCH ve MOUSE'tan **yalnızca birini** açar (SERVER_HELLO'da). MOUSE açıksa telefon TOUCH göndermez.

Etkin özellik = telefonun **ve** sunucunun yeteneklerinin kesişimi.

## Uyumluluk kuralları

- **Eski APK (v0.3) + yeni sunucu:** eski APK HELLO göndermez. Sunucu HELLO görmeden SERVER_HELLO, AUDIO_CONFIG
  ya da AUDIO **göndermemelidir** (eski APK bilinmeyen türleri görüntü decoder'ına verir → bozuk görüntü).
- **Yeni APK + eski sunucu:** eski sunucu HELLO'yu okumaz/yok sayar ve SERVER_HELLO göndermez. Telefon
  SERVER_HELLO almadan TOUCH/MOUSE göndermez; böylece okumayan bir sunucunun soket tamponu dolmaz.
- Bilinmeyen türdeki paketler her iki tarafta da atlanır (uzunluk kadar okunup geçilir).

## Sunucu uygulama notları

- **Linux** (`linux/server/displaytube.c`): varsayılan `--input mouse`. Fare `/dev/uinput` ile mutlak konumlu
  fare cihazı (`DTB DisplayTube Mouse`, `mouse.c`); bileşimciler bunu bütün masaüstü alanına eşlediği için sunucu,
  sanal ekranın masaüstündeki yerini standart xdg-output Wayland protokolüyle izler (`layout.c`) ve noktayı
  kendisi çevirir; masaüstü ayarı gerekmez. Yer bilinmiyorsa tıklamalar yok sayılır.
  `--input touch`: dokunuş `/dev/uinput` ile çoklu dokunmatik ekran cihazı
  (`DTB DisplayTube Touchscreen`) olarak verilir; cihazın `phys` alanı sanal ekranın DRM bağlayıcı adıdır
  (ör. `DVI-I-1`). Yükleyicinin kurduğu udev kuralı bunu `WL_OUTPUT` özelliğine kopyalar; libinput tabanlı
  bileşimciler (Weston, …) dokunmatiği o ekrana eşler; KWin 6.8 bunu yok sayar, KDE'de bir kez
  Sistem Ayarları → Dokunmatik Ekran'dan eşlenir (KDE hatırlar). Ses PipeWire/PulseAudio'dan alınır:
  varsayılan olarak "DisplayTube" adlı sanal ses çıkışı açılır (`--audio sink`), `--audio mirror` varsayılan
  çıkışı kopyalar, `--audio off` kapatır.
- **Windows**: MOUSE için `SendInput` (`MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE`,
  koordinat = sanal ekranın masaüstü dikdörtgeni içindeki nokta, sanal masaüstüne göre 0..65535'e çevrilmiş;
  düğmeler `LEFTDOWN/UP`, `RIGHTDOWN/UP`; tekerlek `MOUSEEVENTF_WHEEL/HWHEEL`, `mouseData` = değer doğrudan,
  yatayda işaret aynı). TOUCH için `InjectSyntheticPointerInput` (PT_TOUCH); ses için WASAPI loopback (float → s16le, 48 kHz stereo).
