# DisplayTube planı

Hedef: Android telefonu USB kablosuyla Windows ve Linux PC'nin **genişletilmiş** ikinci ekranı yapmak. Masaüstü ortamından bağımsız çalışmalı.

## Mimari kararlar
- **Temel:** [Weylus Community Edition](https://github.com/electronstudio/WeylusCommunityEdition) (Rust, AGPL-3.0). Yayın H.264, giriş WebSocket ile gidiyor, bu yüzden `adb reverse` ile gerçek USB üzerinden çalışıyor. Fork'umuz da AGPL-3.0 açık kaynak kalmalı.
- **Windows sanal ekran:** [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) (MIT, Windows 10/11).
- **Linux sanal ekran:** [EVDI](https://github.com/DisplayLink/evdi) kernel modülü (modül GPL-2, libevdi LGPL). Uygulama sanal monitörü kendisi açar ve görüntüyü doğrudan EVDI'den okur, böylece GNOME/KDE/X11 fark etmez. Yedek yollar: boş porta EDID zorlama, HDMI dummy plug.
- **Bağlantı:** `adb reverse tcp:1701`. Weylus CE görüntüyü ve girişi aynı porttan (`/ws`) taşıyor, 9001 gerekmiyor.

## Adımlar
1. **Kodsuz prototip:** Windows'ta VDD + Weylus, Linux'ta Weylus ile ana ekran. Gecikme, kalite ve dokunma ölçümü. Rehber: [adim1-prototip-rehberi.md](adim1-prototip-rehberi.md). Windows'ta hepsi tek komutta: `DisplayTube.bat` (sürücü kontrolü/kurulumu, sanal ekranı 1920x1080 açma, Weylus'u sadece 127.0.0.1'de başlatma, `adb reverse`, telefonda tarayıcıyı açma, kablo takılınca yeniden bağlanma). Not: Sanal ekran 800x600'deyken görüntü kayık çizgilerle bozuluyor; 1920x1080 sorunsuz.
2. **Fork ve tek tık bağlantı:** Weylus CE fork'u. Linux'ta EVDI yakalama backend'i, Windows'ta VDD'yi otomatik açma, `adb reverse`'i otomatik kurma.
3. **Android uygulaması:** Telefon takılınca otomatik bağlanan tam ekran WebView sarmalayıcı.
4. **Paketleme:** Windows kurulum dosyası (VDD dahil), Linux paketi (EVDI DKMS bağımlılığıyla).

## Test ortamları
- Windows 10/11 (DESKTOP-PMC396M)
- Arch Linux, Wayland, AMD RX 6700 XT
