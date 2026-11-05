# Google Play yayın rehberi

Bu klasör DisplayTube Android uygulamasını (`android/`) Google Play'e çıkarmak için gerekenleri toplar.
Durum: 31 Ekim 2026 itibarıyla Play kurallarına göre hazırlandı.

| Dosya | Ne işe yarar |
|---|---|
| `listing/tr-TR.md`, `listing/en-US.md` | Mağaza kaydı: ad, kısa ve tam açıklama, sürüm notu (karakter sınırları içinde) |
| `graphics/icon-512.png` | Play uygulama simgesi (512x512) |
| `graphics/feature-graphic-tr.png`, `feature-graphic-en.png` | Öne çıkan grafik (1024x500) |
| `graphics/make_graphics.py` | Yukarıdaki grafikleri yeniden üretir |
| `../PRIVACY.md` | Gizlilik politikası (TR + EN). Play'e verilecek adres: https://github.com/ArdinyoGitHub/DisplayTube/blob/master/PRIVACY.md |

## 1. Teknik gereksinimler ve durumu

| Gereksinim | Durum |
|---|---|
| Paket adı (applicationId) | `com.displaytube.receiver`. Play'e ilk yüklemeden sonra **asla değiştirilemez**. |
| versionCode / versionName | 3 / 0.3.1. Play'e her yüklemede versionCode artmalı. PC programlarındaki `ApkVersion` (Windows) ve `APK_VERSION_CODE` (Linux) aynı sayıyla güncellenmeli. |
| targetSdk | 36 (Android 16). 31 Ağustos 2026'dan beri yeni uygulamalar ve güncellemeler için Play'in alt sınırı. minSdk 26 (Android 8) aynı kaldı. |
| Dosya biçimi | Play yeni uygulamalarda APK değil **AAB** ister. `android/build.ps1 -Aab` (Windows) ya da `android/build.sh --aab` (Linux) Gradle'sız AAB üretir. GitHub Actions da her değişiklikte APK + AAB üretir (Actions > Android > artifact). |
| İmzalama | **Play App Signing** (zorunlu). Siz AAB'yi kendi *yükleme anahtarınızla* imzalarsınız; Play, kullanıcıya giden APK'yı Google'da saklanan *uygulama imzalama anahtarıyla* yeniden imzalar. Yükleme anahtarı kaybolursa Play Console'dan sıfırlanabilir. |
| İzinler | Yalnızca `INTERNET` (127.0.0.1 soketi için). `usesCleartextTraffic` kaldırıldı (ham TCP soketi bu ayardan etkilenmez), `allowBackup=false` eklendi. Özel izin beyanı gerekmez. |
| Reklam kimliği (AD_ID) | Kullanılmıyor. Play Console'daki "Reklam kimliği" beyanında **Hayır** seçin. |

### Bilinen davranış değişiklikleri (targetSdk 36)
- Android 15+ uygulamayı kenardan kenara (edge-to-edge) çizer. DisplayTube zaten tam ekran ve sürükleyici (immersive) modda olduğu için etkisi yok.
- Android 16'da büyük ekranlarda (tablet, katlanabilir; en kısa kenar 600dp ve üstü) `screenOrientation="sensorLandscape"` yok sayılır. Tablette dikey tutulursa görüntü ekrana sığdırılır. Telefonlarda değişiklik yok.

## 2. İmza çakışması: PC paketindeki APK ile Play sürümü

PC programları (Windows ve Linux) telefona kendi paketlerindeki `DisplayTube.apk` dosyasını `adb install -r` ile kurar. Bu APK şu an **debug anahtarıyla** imzalı. Play'den kurulan sürüm ise Play'in anahtarıyla imzalı olacak. Android, farklı imzalı bir sürümün üzerine kurmaya izin vermez:

- Telefonda PC'nin kurduğu sürüm varken Play'den kurmak ya da tersi, önce uygulamayı kaldırmayı gerektirir.
- PC programı, telefondaki sürüm paketteki sürümden eski değilse kurmaya çalışmaz, bu yüzden Play sürümü yüklü olan kullanıcıda sorun çıkmaz.

**Öneri:** Play'e ilk sürümü yükledikten sonra Play Console > *Test ve yayınlama > Uygulama paketi gezgini* (App bundle explorer) bölümünden **Play imzalı evrensel APK**'yı (signed universal APK) indirin ve sonraki PC paketlerine `DisplayTube.apk` olarak onu koyun. Böylece GitHub'dan ve Play'den kurulan sürümler birbirini güncelleyebilir. Mevcut kullanıcılar bir kerelik kaldırıp kurmak zorunda kalır (Linux programı bu durumda "İmza farklı" uyarısı veriyor; Windows programı da kurulum hatasını günlüğe yazıyor).

## 3. Play Console form cevapları

**Uygulama mı oyun mu:** Uygulama. **Ücretsiz mi ücretli mi:** Ücretsiz. **Kategori:** Araçlar (Tools).
**İletişim e-postası:** Zorunlu, mağazada görünür. İsterseniz ayrı bir adres açın.

**Gizlilik politikası:** https://github.com/ArdinyoGitHub/DisplayTube/blob/master/PRIVACY.md

**Uygulama erişimi (App access):** Giriş ya da hesap yok. Yine de "Tüm işlevler ya da bazıları kısıtlı" seçeneğini seçip incelemeciye şu notu yazmak, "uygulama bir şey yapmıyor" reddini önlemeye yardımcı olur:
> No login is required. DisplayTube is a USB display receiver: it shows a "Waiting for computer" screen until the free companion PC program (https://github.com/ArdinyoGitHub/DisplayTube/releases, Windows 10/11 or Linux) is running and the phone is connected over USB with USB debugging enabled. The PC then streams its virtual second screen to the phone over adb reverse (127.0.0.1:27183).

Tanıtım videosu eklerseniz nota bağlantısını da yazın.

**Reklamlar:** Hayır, reklam içermiyor.

**İçerik derecelendirmesi (IARC anketi):** Kategori "Yardımcı program, üretkenlik, iletişim ya da diğer". Şiddet, cinsellik, küfür, kumar, uyuşturucu, kullanıcılar arası etkileşim, konum paylaşımı, dijital satın alma: hepsi **Hayır**. Beklenen sonuç: 3+ / Herkes.

**Hedef kitle:** **18 yaş ve üstü** seçin (ya da 13+). Çocukları kapsayan bir yaş grubu seçmek Aile politikası ek yükümlülükleri getirir. "Uygulama çocukların ilgisini çekebilir mi?" sorusuna **Hayır**.

**Veri güvenliği (Data safety):**
- Uygulamanız gerekli kullanıcı verisi türlerinden herhangi birini topluyor ya da paylaşıyor mu? **Hayır.**
- (Bu cevapla şifreleme ve silme talebi soruları sorulmaz.) Görüntü, cihazdan geliştiriciye ya da üçüncü tarafa hiç gitmediği için Play tanımına göre "toplanan veri" sayılmaz.

**Haber uygulaması, sağlık, finans, devlet uygulaması, COVID-19:** Hepsi Hayır.

**Mağaza grafikleri:**
- Uygulama simgesi: `graphics/icon-512.png`
- Öne çıkan grafik: `graphics/feature-graphic-tr.png` (TR kaydı), `feature-graphic-en.png` (EN kaydı)
- **Telefon ekran görüntüleri: en az 2 adet, sizin çekmeniz gerekiyor** (9:16 ya da 16:9, kenarı 320-3840 px). Öneri: (1) yayın sırasında telefonun ekran görüntüsü (bilgisayarın ikinci ekranı görünür, yatay); (2) "Bilgisayar bekleniyor" ekranı. Telefonda yayın sırasında güç + ses kısma tuşlarıyla çekebilirsiniz. Görüntüler uygulamayı gerçekte olduğu gibi göstermeli.
- İsteğe bağlı ama faydalı: kısa bir YouTube tanıtım videosu (kurulum + kullanım). İncelemeciye de uygulamanın nasıl çalıştığını gösterir.

## 4. Politika riskleri

1. **Asgari işlevsellik / "uygulama çalışmıyor" reddi (en büyük risk).** İncelemeci PC programı olmadan yalnızca bekleme ekranını görür. Önlemler: açıklamanın en üstünde PC programı şartı ve indirme bağlantısı (hazır), Uygulama erişimi notu (yukarıda), tanıtım videosu ve gerçek kullanım ekran görüntüleri. Reddedilirse itiraz formunda aynı açıklamayı ve video bağlantısını verin.
2. **Yanıltıcı iddialar.** Açıklamada "sıfır gecikme", "en iyi" gibi ifadeler yok; öyle kalsın. Dokunmatik ve ses desteği olmadığı açıkça yazıyor.
3. **USB hata ayıklama talimatı.** Kullanıcıdan geliştirici seçeneklerini açmasını istemek politikaya aykırı değil (scrcpy benzeri uygulamalar bunu yapıyor), ama uygulama bunu kendi kendine değiştirmeye çalışmamalı. Çalışmıyor.
4. **Ad.** "DisplayTube" adındaki "Tube" düşük bir marka benzerliği riski taşır. Simge ve renkler YouTube'a benzemiyor; açıklamada YouTube'dan bahsedilmiyor. Şimdilik sorun beklemiyorum.
5. **Kapalı test şartı.** 13 Kasım 2023'ten sonra açılan kişisel geliştirici hesaplarında üretim (herkese açık) yayına başvurmadan önce **en az 12 test kullanıcısının 14 gün kesintisiz** kapalı teste katılmış olması gerekir. Test kullanıcılarının da PC programını kurup uygulamayı gerçekten kullanması, Google'ın üretim başvurusundaki "test sırasında ne öğrendiniz" sorularına cevap vermeyi kolaylaştırır.

## 5. Yükleme anahtarı oluşturma (bir kez, kendi bilgisayarınızda)

```
keytool -genkeypair -v -keystore upload.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000
```
- `upload.jks` dosyasını ve şifreleri depo **dışında**, yedekli bir yerde saklayın (ör. şifre yöneticisi). `.gitignore` `*.jks` ve `*.keystore` dosyalarını zaten dışarıda tutuyor.
- İmzalı AAB üretmek için: `android/build.ps1 -Aab` / `android/build.sh --aab` (ortam değişkenleri betiklerin başında yazıyor).
- GitHub Actions'ın imzalı AAB üretmesini isterseniz (isteğe bağlı) depo sırlarına `UPLOAD_KEYSTORE_BASE64`, `UPLOAD_STORE_PASSWORD`, `UPLOAD_KEY_PASSWORD`, `UPLOAD_KEY_ALIAS` ekleyin. Eklemezseniz Actions imzasız AAB üretir; onu yerelde imzalamanız gerekir.

## 6. Sizin yapmanız gereken adımlar (sırayla)

1. **Geliştirici hesabı:** https://play.google.com/console/signup adresinden **kişisel** hesap açın, 25 USD'lik tek seferlik ücreti ödeyin.
2. **Kimlik doğrulama:** Kimlik belgesi, telefon numarası ve e-posta doğrulaması; ayrıca Play Console mobil uygulamasıyla bir Android cihazdan erişim doğrulaması. Birkaç gün sürebilir.
3. **Yükleme anahtarı:** Bölüm 5'teki komutla oluşturun ve güvenli yerde yedekleyin.
4. **Uygulama oluştur:** Ad "DisplayTube: USB İkinci Ekran", varsayılan dil Türkçe (ya da İngilizce), Uygulama, Ücretsiz.
5. **İmzalı AAB:** `android/build.ps1 -Aab` ile üretin.
6. **Kapalı test:** *Test > Kapalı test* bölümünde bir kanal açın, AAB'yi yükleyin (ilk yüklemede Play App Signing'i "Google tarafından oluşturulan anahtar" ile kabul edin), 12+ test kullanıcısının e-postasını ekleyin ve katılım bağlantısını gönderin.
7. **Formlar:** Bölüm 3'teki cevaplarla Uygulama içeriği (App content) bölümünü ve Mağaza kaydını doldurun, ekran görüntülerini yükleyin.
8. **14 gün bekleyin**, test kullanıcıları katılımda kalsın. Sonra *Üretim erişimi için başvur* ile formu doldurun.
9. Onaydan sonra Play imzalı evrensel APK'yı indirip PC paketlerine koyun (Bölüm 2).
