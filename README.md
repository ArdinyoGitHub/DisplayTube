# DisplayTube

Turns an Android phone into a second (extended) Windows display over a **USB cable**. No Wi-Fi or network needed.

*Android telefonu **USB kablosuyla** Windows bilgisayarın **ikinci (genişletilmiş) ekranı** yapar. Wi-Fi ya da ağ gerekmez. Türkçe açıklama aşağıda.*

---

## English

### How it works
1. The open-source **Virtual Display Driver** adds a virtual monitor that Windows treats like a real one.
2. DisplayTube captures that display with Windows Desktop Duplication. It converts frames to NV12 on the GPU and encodes them with the GPU's hardware H.264 encoder in low-latency mode, falling back to Windows' software encoder when no hardware encoder is available. It works on AMD, NVIDIA and Intel GPUs, including integrated graphics.
3. Video reaches the phone only over USB via `adb reverse`. The PC listens on `127.0.0.1` only, and no port is opened on the network.
4. The DisplayTube Android app shows the stream full screen using the phone's hardware decoder.

Measured latency is about 20–30 ms on the PC side, and about 60–75 ms in total including decoding and display on the phone.

### Requirements
- Windows 10 (2004+) or Windows 11, 64-bit
- An Android 8.0+ phone and a USB data cable
- **USB debugging** enabled on the phone: tap *Settings > About phone > Build number* 7 times, then enable *Developer options > USB debugging*.

### Install and use
1. Extract `DisplayTube-v0.3-win-x64.zip` and run `DisplayTube.exe`. It lives in the notification area next to the clock.
2. On first run it asks for two confirmations:
   - **Android tools (adb):** if no adb is found, Google's official *platform-tools* (~15 MB) are downloaded from `dl.google.com` with your permission.
   - **Virtual display driver:** administrator permission (UAC) is requested, and the driver's signing certificate is added to Windows' trusted list. This is needed because the driver is self-signed.
3. Connect the phone over USB and accept the *"Allow USB debugging"* prompt on the phone.
4. DisplayTube installs and opens the app on the phone, and sets the virtual display to the phone's aspect ratio.
5. Unplugging and replugging the cable reconnects automatically.

Tray menu: **Start/Stop**, **Resolution** (Match phone / Don't change / 1920x1080 / 2560x1440), **Start with Windows**, **Open log**.

Settings and log: `%APPDATA%\DisplayTube\`

### Known limitations
- Video only for now. There's no touch input from the phone to the PC.
- Windows does not allow screen capture while the PC is locked. Streaming resumes after unlocking.
- Large file transfers over the same cable while streaming can briefly affect the picture.

### Linux
The Linux version works with any desktop (GNOME, KDE, wlroots, X11) and any graphics card. Extract `DisplayTube-v0.3-linux.tar.gz` and run `./install.sh`. The installer downloads what is needed (EVDI virtual display driver, adb, FFmpeg, VAAPI driver). If a step fails, it tells you at the end what went wrong and how to fix it. Details: [linux/README.md](linux/README.md)

---

## Türkçe

### Nasıl çalışır?
1. Açık kaynaklı **Virtual Display Driver** Windows'a gerçek bir monitör gibi görünen sanal bir ekran ekler.
2. DisplayTube bu ekranı Windows'un Desktop Duplication API'siyle yakalar. Görüntüyü ekran kartında NV12'ye çevirir ve ekran kartının donanım H.264 kodlayıcısıyla, düşük gecikme modunda kodlar. Donanım kodlayıcı yoksa Windows'un yazılım kodlayıcısı kullanılır. AMD, NVIDIA ve Intel kartlarda (tümleşik grafik dahil) çalışır.
3. Görüntü `adb reverse` ile yalnızca USB üzerinden telefona gider. Bilgisayar tarafında sadece `127.0.0.1` dinlenir, ağa hiçbir port açılmaz.
4. Telefondaki DisplayTube uygulaması görüntüyü donanım çözücüsüyle tam ekran gösterir.

Ölçülen gecikme bilgisayar tarafında yaklaşık 20-30 ms. Telefonda çözme ve ekrana çizim de eklenince toplam yaklaşık 60-75 ms.

### Gereksinimler
- Windows 10 (2004+) ya da Windows 11, 64 bit
- Android 8.0 ya da üstü bir telefon ve USB veri kablosu
- Telefonda **USB hata ayıklama** açık olmalı: *Ayarlar > Telefon hakkında > Yapım numarası*'na 7 kez dokunun, sonra *Geliştirici seçenekleri > USB hata ayıklama*'yı açın.

### Kurulum ve kullanım
1. `DisplayTube-v0.3-win-x64.zip` dosyasını bir klasöre çıkarın ve `DisplayTube.exe`'yi çalıştırın. Program saatin yanındaki bildirim alanına yerleşir.
2. İlk çalıştırmada iki onay istenir:
   - **Android araçları (adb):** Bilgisayarda adb yoksa, Google'ın resmî *platform-tools* paketi (~15 MB) izninizle `dl.google.com`'dan indirilir.
   - **Sanal ekran sürücüsü:** Yönetici izni (UAC) istenir. Sürücünün imza sertifikası Windows'un güvenilir listesine eklenir. Bu, sürücünün kendinden imzalı olması nedeniyle gereklidir.
3. Telefonu USB ile bağlayın ve telefonda çıkan *"USB hata ayıklamaya izin ver"* sorusunu onaylayın.
4. DisplayTube telefona uygulamayı kendisi kurar ve açar. Sanal ekran telefonun ekran oranına ayarlanır.
5. Kablo çıkarılıp takıldığında bağlantı kendiliğinden yeniden kurulur.

Bildirim alanı menüsü: **Başlat/Durdur**, **Çözünürlük** (Telefona göre / Değiştirme / 1920x1080 / 2560x1440), **Windows açılışında başlat**, **Günlüğü aç**.

Ayarlar ve günlük: `%APPDATA%\DisplayTube\`

### Bilinen sınırlamalar
- Şimdilik yalnızca görüntü aktarılıyor. Telefondan dokunmayla bilgisayarı kontrol etme yok.
- Ekran kilitliyken Windows ekran yakalamaya izin vermez. Kilit açılınca yayın kendiliğinden devam eder.
- Yayın sırasında aynı kablodan büyük dosya aktarımı yapmak görüntüyü kısa süre etkileyebilir.

### Linux
Linux sürümü masaüstünden (GNOME, KDE, wlroots, X11) ve ekran kartından bağımsızdır. `DisplayTube-v0.3-linux.tar.gz` dosyasını açıp `./install.sh` çalıştırın. Yükleyici gerekenleri (EVDI sanal ekran sürücüsü, adb, FFmpeg, VAAPI sürücüsü) indirir. Bir adım başarısız olursa sonda nedenini ve çözümünü yazar. Ayrıntılar: [linux/README.md](linux/README.md)

---

## Building from source

| Part | Folder | Build |
|---|---|---|
| Windows app + capture engine | `pc/DisplayTubeApp`, `pc/DisplayTubeCapture` | .NET 8 SDK |
| Android receiver | `android/` | JDK 17 + Android SDK (platform 36, build-tools 36.0.0), no Gradle: `android/build.ps1` (`-Aab` for the Play Store bundle) |
| Release zip | `release.ps1` | builds everything into `release/` |
| Linux server | `linux/server` | C, libevdi + FFmpeg (libavcodec/libavfilter): `make` |
| Linux release | `linux/release.sh` | `release/DisplayTube-v<version>-linux.tar.gz` |

An older FFmpeg-based pipeline (`pc/stream.ps1`, `pc/DisplayTubeServer.cs`) and a Weylus-based prototype (`DisplayTube-weylus.bat`) are kept as fallbacks for development.

## License

DisplayTube is released under the [MIT License](LICENSE). Third-party components are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
