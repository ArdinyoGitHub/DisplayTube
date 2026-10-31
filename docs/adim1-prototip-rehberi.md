# Adım 1: Kodsuz prototip (Weylus + sanal ekran + USB)

Amaç: Hiç kod yazmadan, Android telefonu USB üzerinden PC'nin **genişletilmiş** ikinci ekranı yapmak ve gecikmeyi, akıcılığı, görüntü kalitesini ölçmek. Sonuçlar 2. adımda neyi değiştireceğimizi belirleyecek.

Kullanılan parçalar:
- [Weylus Community Edition](https://github.com/electronstudio/WeylusCommunityEdition): Ekranı tarayıcıya H.264 olarak yayınlar, girişleri WebSocket ile geri alır. Portlar: **1701** (web) ve **9001** (websocket).
- [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) (sadece Windows): Gerçek bir monitör gibi görünen sanal ekran.
- **ADB** (Android Platform Tools): `adb reverse` ile telefondaki `127.0.0.1` adresini USB üzerinden PC'ye yönlendirir. Wi-Fi gerekmez.

---

## Ortak hazırlık: Telefon ve ADB

1. Telefonda **Ayarlar > Telefon hakkında > Yapı numarası**'na 7 kez dokun, Geliştirici seçenekleri açılır.
2. **Geliştirici seçenekleri > USB hata ayıklama**'yı aç.
3. PC'ye Android Platform Tools'u kur:
   - Windows: `winget install Google.PlatformTools` (ya da developer.android.com'dan zip indirip PATH'e ekle)
   - Linux (Debian/Ubuntu): `sudo apt install adb` · Fedora: `sudo dnf install android-tools` · Arch: `sudo pacman -S android-tools`
4. Telefonu USB ile bağla ve çalıştır:
   ```
   adb devices
   ```
   Telefonda çıkan "USB hata ayıklamaya izin ver" sorusunu onayla. Listede cihaz `device` olarak görünmeli (`unauthorized` değil).
5. Telefona **Firefox** kur (Weylus en iyi Firefox 80+ ile çalışıyor; Chrome'u da ayrıca deneyebilirsin).

---

## Windows

### 1. Sanal ekranı kur
```
winget install --id=VirtualDrivers.Virtual-Display-Driver -e
```
(Alternatif: GitHub sayfasındaki "Driver Installer (Windows 10/11)".)

Kurulumdan sonra:
- **Ayarlar > Sistem > Ekran**'da yeni bir monitör görünmeli.
- "Bu ekranları genişlet" seç, sanal ekranı fiziksel ekranın sağına/soluna sürükle.
- Çözünürlüğü telefonuna yakın bir değere ayarla (ör. 2400x1080 telefon için 1920x864 ya da 2400x1080). Çözünürlükler `C:\VirtualDisplayDriver\vdd_settings.xml` dosyasından veya Virtual Driver Control uygulamasından eklenebilir.

### 2. Weylus'u kur ve başlat
1. [Releases](https://github.com/electronstudio/WeylusCommunityEdition/releases) sayfasından Windows sürümünü indirip kur.
2. Weylus'u aç, bir erişim kodu (access code) belirle, **Start**'a bas.
3. Windows Güvenlik Duvarı sorarsa izin ver (USB üzerinden bile yerel bağlantı açılıyor).

### 3. USB üzerinden bağlan
```
adb reverse tcp:1701 tcp:1701
adb reverse tcp:9001 tcp:9001
```
Telefonda Firefox'ta `http://127.0.0.1:1701` adresini aç, erişim kodunu gir. **Capture** menüsünden sanal ekranı seç.

Not: Windows'ta Weylus sadece fareyi kontrol eder (çoklu dokunma ve kalem yalnızca Linux'ta). Pencere yakalama da yok, tüm ekran yayınlanır; bizim için sorun değil.

---

## Linux

Önce masaüstü oturumunu öğren:
```
echo $XDG_SESSION_TYPE      # x11 ya da wayland
lspci | grep -iE 'vga|3d'   # GPU
```

### 1. Weylus'u kur
```
flatpak install flathub io.github.electronstudio.WeylusCommunityEdition
```
Dokunma/kalem girişi istiyorsan `/dev/uinput` izni gerekir:
```
sudo groupadd -f uinput
sudo usermod -aG uinput $USER
echo 'KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/60-weylus.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```
Sonra oturumu kapatıp aç. (Uyarı: `uinput` grubundaki kullanıcılar sistem genelinde sahte giriş üretebilir.)

### 2. Sanal ekran oluştur

> **Güncelleme:** Ürünün kendisinde Linux sanal ekranı masaüstünden bağımsız olarak **EVDI** kernel modülüyle bizim uygulamamız oluşturacak (2. adım). Prototipte sanal ekranla uğraşma: Capture menüsünden **ana ekranı** seçip sadece gecikme, kalite ve dokunma ölçümünü yap. Aşağıdaki yöntemler isteğe bağlı.

Hangisi senin sistemine uyuyorsa:

**A) X11 + Intel GPU** (Weylus'un resmi yöntemi). Uyarı: Yanlış ayar X'in açılmasını engelleyebilir, geri dönmek için TTY'ye (Ctrl+Alt+F3) geçip dosyayı silmeyi bil.

`/etc/X11/xorg.conf.d/20-intel.conf`:
```
Section "Device"
    Identifier "intelgpu0"
    Driver "intel"
    Option "VirtualHeads" "1"
EndSection
```
`xf86-video-intel` paketini kur, yeniden başlat. Sonra:
```
gtf 1920 864 60          # çıktıdaki Modeline değerlerini aşağıya kopyala
xrandr --newmode "1920x864_60.00" <gtf'nin verdiği sayılar>
xrandr --addmode VIRTUAL1 1920x864_60.00
xrandr --output VIRTUAL1 --mode 1920x864_60.00 --right-of <ana ekranın adı>
```

**B) X11 + AMD/NVIDIA/diğer:** Kullanılmayan bir çıkışı (ör. boş HDMI portu) mod ekleyip zorla açmayı dene:
```
xrandr                     # "disconnected" çıkışların adını bul, ör. HDMI-1
xrandr --addmode HDMI-1 1920x864_60.00   # önce --newmode ile modu ekle (A'daki gibi)
xrandr --output HDMI-1 --mode 1920x864_60.00 --right-of <ana ekran>
```
Bu her sürücüde çalışmayabilir. Çalışmazsa en garantili yol ucuz bir **HDMI dummy plug** (sahte monitör adaptörü).

**C) Wayland:** Weylus burada deneysel. GNOME'da sanal monitör oluşturmanın hazır bir kullanıcı yolu yok; kısa vadede en pratik çözüm X11 oturumuna geçmek ya da HDMI dummy plug. Sway kullanıyorsan `swaymsg create_output` ile başsız (headless) çıkış eklenebilir (denenmemiş).

> Hangi dağıtım/masaüstü/GPU'da olduğunu yazarsan bu kısmı sana özel netleştiririm.

### 3. Başlat ve bağlan
Weylus'ta erişim kodu belirle, Start'a bas. Güvenlik duvarı varsa: `sudo ufw allow 1701/tcp && sudo ufw allow 9001/tcp`.
```
adb reverse tcp:1701 tcp:1701
adb reverse tcp:9001 tcp:9001
```
Telefonda `http://127.0.0.1:1701` aç, Capture menüsünden sanal ekranı seç.

İsteğe bağlı donanım hızlandırma: Weylus ayarlarında VAAPI (Intel/AMD) ya da NVENC (NVIDIA). Windows'ta NVENC veya MediaFoundation. Varsayılan olarak kapalı; önce kapalıyken, sonra açıkken ölç.

---

## Ölçüm

Her platformda şunları not et:

1. **Gecikme:** PC'de bir kronometre sitesini (milisaniyeli) hem ana ekranda hem telefon ekranında görünecek şekilde aç, ikisini aynı fotoğrafta çek. Farkı 3 kez ölç, ortalamasını al.
2. **Akıcılık:** Sanal ekranda bir video oynat ya da pencere sürükle; takılma var mı?
3. **Görüntü kalitesi:** Küçük yazılar okunuyor mu, bulanıklık var mı?
4. **CPU kullanımı:** Görev Yöneticisi / `htop` ile Weylus'un yüzdesi.
5. **Giriş:** Telefondan dokununca fare doğru yere gidiyor mu?

| | Windows | Linux |
|---|---|---|
| Sanal ekran yöntemi | VDD | A / B / C / dummy |
| Çözünürlük | | |
| Gecikme (ms, ort.) | | |
| Akıcılık (iyi/orta/kötü) | | |
| Yazı okunaklılığı | | |
| CPU % (Weylus) | | |
| Donanım hızlandırma | açık/kapalı | açık/kapalı |
| Dokunma çalışıyor mu | | |
| Sorunlar | | |

Tabloyu doldurup thread'e yazman (veya fotoğrafını atman) yeterli.

## Sık karşılaşılan sorunlar
- **Sayfa açılmıyor:** `adb reverse --list` ile iki portun da yönlendirildiğini kontrol et. Kablo çıkıp takılınca `adb reverse` komutlarını tekrar çalıştırman gerekir.
- **Bağlanıyor ama görüntü yok:** 9001 portu yönlendirilmemiş ya da güvenlik duvarına takılmış olabilir.
- **Sanal ekran Capture menüsünde yok:** Weylus'u sanal ekranı oluşturduktan *sonra* başlat.
