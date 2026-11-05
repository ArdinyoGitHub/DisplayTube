# DisplayTube Gizlilik Politikası / Privacy Policy

Son güncelleme / Last updated: 31 Ekim 2026 / October 31, 2026

## Türkçe

DisplayTube, Android telefonu USB kablosuyla bilgisayarın ikinci ekranı yapan açık kaynaklı (MIT lisanslı) bir uygulamadır. Bu politika Android uygulaması (`com.displaytube.receiver`) ve bilgisayar programı için geçerlidir.

**Toplanan veri yok.** DisplayTube hiçbir kişisel veri toplamaz, saklamaz, paylaşmaz ya da satmaz. Hesap, kayıt, reklam, analiz (analytics), çökme raporlama ya da üçüncü taraf SDK'sı yoktur.

**Ağ kullanımı.** Android uygulaması yalnızca telefonun kendi içindeki `127.0.0.1:27183` adresine bağlanır. Bu bağlantı `adb reverse` ile USB kablosu üzerinden yalnızca sizin bilgisayarınızdaki DisplayTube programına iletilir. Uygulama internete ya da yerel ağa bağlanmaz. `INTERNET` izni yalnızca Android'in bu yerel (localhost) soketi açmak için istediği izin olduğu için vardır.

**Görüntü verisi.** Bilgisayarınızın ekran görüntüsü yalnızca USB kablosu üzerinden sizin telefonunuza gider, ekranda gösterilir ve hiçbir yere kaydedilmez ya da gönderilmez.

**İzinler.** Uygulama kamera, mikrofon, konum, rehber, depolama ya da benzeri hiçbir izin istemez.

**Bilgisayar programı.** Windows/Linux programı yalnızca sizin onayınızla Google'ın resmî Android platform araçlarını (adb) ve Linux'ta gerekli sistem paketleri ile EVDI sanal ekran sürücüsünün kaynak kodunu (GitHub/AUR) indirebilir. Bu indirmeler dışında hiçbir sunucuya bağlanmaz ve veri göndermez. Ayarlar ve günlük dosyası yalnızca bilgisayarınızda tutulur.

**Çocuklar.** Uygulama çocuklara yönelik değildir ve kimseden veri toplamaz.

**Değişiklikler.** Bu politika değişirse güncel hali bu sayfada yayımlanır.

**İletişim.** Sorular için: https://github.com/ArdinyoGitHub/DisplayTube/issues

## English

DisplayTube is an open-source (MIT licensed) app that turns an Android phone into a second display for a computer over a USB cable. This policy covers the Android app (`com.displaytube.receiver`) and the desktop program.

**No data is collected.** DisplayTube does not collect, store, share or sell any personal data. There are no accounts, sign-ups, ads, analytics, crash reporting or third-party SDKs.

**Network use.** The Android app only connects to `127.0.0.1:27183` on the phone itself. Through `adb reverse`, this connection is forwarded over the USB cable to the DisplayTube program on your own computer only. The app does not connect to the internet or to the local network. The `INTERNET` permission exists only because Android requires it to open this local (localhost) socket.

**Screen data.** Your computer's screen image travels only over the USB cable to your phone, is shown on screen and is never saved or sent anywhere.

**Permissions.** The app does not request camera, microphone, location, contacts, storage or any similar permission.

**Desktop program.** The Windows/Linux program may download Google's official Android platform tools (adb) and, on Linux, required system packages and the EVDI virtual display driver source (GitHub/AUR), only with your consent. Apart from those downloads it does not connect to any server or send any data. Settings and the log file stay on your computer.

**Children.** The app is not directed at children and collects no data from anyone.

**Changes.** If this policy changes, the current version will be published on this page.

**Contact.** For questions: https://github.com/ArdinyoGitHub/DisplayTube/issues
