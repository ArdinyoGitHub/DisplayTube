#!/usr/bin/env bash
# DisplayTube Linux yukleyicisi.
#
# Gerekenleri indirip kurar, sunucuyu derler ve yerlestirir:
#   - EVDI sanal ekran surucusu (DKMS kernel modulu + libevdi)
#   - adb (telefon baglantisi) ve USB izin kurallari
#   - FFmpeg kutuphaneleri + ekran kartina uygun VAAPI surucusu (donanim H.264)
#   - derleme araclari ve calisan kernel'in basliklari
# Bir adim basarisiz olursa kurulum durmaz; sonda neyin eksik kaldigi ve nasil
# duzeltilecegi yazilir, masaustu bildirimi gosterilir. Cikis kodu: 0 tam, 1 eksik.
#
# Kullanim: ./install.sh [--yes] [--autostart|--no-autostart] [--prefix /usr/local]
#           ./install.sh --uninstall
#           ./install.sh --dry-run      (hicbir sey degistirmeden ne yapilacagini gosterir)
set -uo pipefail

VERSION=0.3
EVDI_VERSION=1.15.1
EVDI_SHA256=b120df303d14be09062157aab17a8598746c0caf2e076ff3388b4091186cf2d9
EVDI_URL="https://github.com/DisplayLink/evdi/archive/v$EVDI_VERSION/evdi-$EVDI_VERSION.tar.gz"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/usr/local
ASSUME_YES=0
DRY_RUN=0
AUTOSTART=ask
UNINSTALL=0
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/displaytube"
LOG="$LOG_DIR/install.log"
WORK=""

PROBLEMS=()     # "baslik|cozum"
WARNINGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --autostart) AUTOSTART=yes ;;
    --no-autostart) AUTOSTART=no ;;
    --prefix) PREFIX="$2"; shift ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen secenek: $1 (--help)"; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- cikti

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
mkdir -p "$LOG_DIR"
: > "$LOG"
log()  { printf '%s\n' "$*" >> "$LOG"; }
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; log "==> $*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; log "  OK $*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; log "  UYARI $*"; WARNINGS+=("$*"); }
problem() {   # problem "ne olmadi" "kullanici ne yapmali"
  printf '  %s✗ %s%s\n' "$R" "$1" "$N"
  log "  HATA $1 | $2"
  PROBLEMS+=("$1|$2")
}

notify() {   # notify normal|critical "mesaj"
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a DisplayTube -u "$1" -i video-display "DisplayTube kurulumu" "$2" >/dev/null 2>&1 || true
}

confirm() {   # confirm "soru" -> 0 evet
  [ "$ASSUME_YES" = 1 ] && return 0
  local a
  read -r -p "$1 [E/h] " a </dev/tty || return 1
  case "$a" in ""|e|E|evet|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# Komutu calistirir, ciktiyi log'a yazar. Basarisizsa son satirlari gosterir.
run() {
  log "\$ $*"
  if [ "$DRY_RUN" = 1 ]; then printf '    [deneme] %s\n' "$*"; return 0; fi
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$LOG"
  if [ $rc -ne 0 ]; then
    printf '%s\n' "$out" | tail -n 6 | sed 's/^/      /'
  fi
  return $rc
}

SUDO=()
root() {
  if [ "$DRY_RUN" = 1 ]; then run "${SUDO[@]}" "$@"; return; fi
  log "\$ ${SUDO[*]} $*"
  local out rc
  out="$("${SUDO[@]}" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$LOG"
  [ $rc -ne 0 ] && printf '%s\n' "$out" | tail -n 6 | sed 's/^/      /'
  return $rc
}
root_write() {   # root_write dosya "icerik"
  log "\$ yaz $1: $2"
  if [ "$DRY_RUN" = 1 ]; then printf '    [deneme] %s <- %s\n' "$1" "$2"; return 0; fi
  local out rc
  out="$(printf '%s\n' "$2" | "${SUDO[@]}" tee "$1" 2>&1 >/dev/null)"; rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >> "$LOG"
  return $rc
}

# Indirme hatasinda sebep tahmini: internet mi, depo mu?
net_hint() {
  if command -v curl >/dev/null 2>&1 && ! curl -fsS -m 8 -o /dev/null https://github.com 2>/dev/null; then
    echo "Internet baglantisi yok ya da engelli gorunuyor. Baglantiyi kontrol edip yukleyiciyi yeniden calistirin."
  else
    echo "Paket deposuna ulasilamadi ya da paket bulunamadi. Ayrintilar: $LOG"
  fi
}

finish() {
  [ -n "$WORK" ] && rm -rf "$WORK"
  echo
  if [ ${#PROBLEMS[@]} -eq 0 ]; then
    printf '%s%sDisplayTube %s kuruldu.%s\n' "$B" "$G" "$VERSION" "$N"
    [ ${#WARNINGS[@]} -gt 0 ] && printf '%d uyari var (yukarida, %s isaretli).\n' "${#WARNINGS[@]}" "!"
    echo "Telefonu USB ile baglayin; uygulama kendiliginden acilir."
    [ "$DRY_RUN" = 1 ] || notify normal "Kurulum tamamlandi. Telefonu USB ile baglayin."
    exit 0
  fi
  printf '%s%sKurulum eksik kaldi: %d sorun%s\n' "$B" "$R" "${#PROBLEMS[@]}" "$N"
  local p i=1
  for p in "${PROBLEMS[@]}"; do
    printf '\n %s%d) %s%s\n    Cozum: %s\n' "$B" "$i" "${p%%|*}" "$N" "${p#*|}"
    i=$((i + 1))
  done
  printf '\nTum ayrintilar: %s\n' "$LOG"
  printf 'Sorunu giderdikten sonra yukleyiciyi yeniden calistirin; kurulu olanlar atlanir.\n'
  notify critical "Kurulum eksik kaldi (${#PROBLEMS[@]} sorun): ${PROBLEMS[0]%%|*}. Ayrintilar terminalde ve $LOG dosyasinda."
  exit 1
}

# ---------------------------------------------------------------- on kontroller

if [ "$(id -u)" = 0 ]; then
  echo "Yukleyiciyi root olarak degil, kendi kullanicinizla calistirin (gerektiginde sudo sorulur)."
  exit 2
fi
if command -v sudo >/dev/null 2>&1; then SUDO=(sudo)
elif command -v doas >/dev/null 2>&1; then SUDO=(doas)
elif command -v pkexec >/dev/null 2>&1; then SUDO=(pkexec)
else
  echo "sudo, doas ya da pkexec bulunamadi; yonetici yetkisi alinamiyor."
  notify critical "Kurulum baslatilamadi: yonetici yetkisi icin sudo bulunamadi."
  exit 1
fi

. /etc/os-release 2>/dev/null || true
DISTRO_ID="${ID:-bilinmiyor}"
DISTRO_LIKE="${ID_LIKE:-}"
case " $DISTRO_ID $DISTRO_LIKE " in
  *" arch "*) FAMILY=arch ;;
  *" debian "*|*" ubuntu "*) FAMILY=debian ;;
  *" fedora "*|*" rhel "*) FAMILY=fedora ;;
  *" suse "*|*" opensuse "*) FAMILY=suse ;;
  *) FAMILY=other ;;
esac
KERNEL="$(uname -r)"

# Ekran kartlari (PCI sinif 03xx): 1002 AMD, 8086 Intel, 10de NVIDIA
GPUS=""
for d in /sys/bus/pci/devices/*; do
  [ -r "$d/class" ] || continue
  case "$(cat "$d/class")" in 0x03*)
    case "$(cat "$d/vendor")" in
      0x1002) GPUS="$GPUS amd" ;; 0x8086) GPUS="$GPUS intel" ;; 0x10de) GPUS="$GPUS nvidia" ;;
    esac ;;
  esac
done
has_gpu() { case " $GPUS " in *" $1 "*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- kaldirma

if [ "$UNINSTALL" = 1 ]; then
  say "DisplayTube kaldiriliyor"
  if [ "$DRY_RUN" = 0 ] && ! "${SUDO[@]}" -v 2>/dev/null; then [ "${SUDO[0]}" = sudo ] && exit 1; fi
  run systemctl --user disable --now displaytube.service || true
  run rm -f "$HOME/.config/systemd/user/displaytube.service"
  run systemctl --user daemon-reload || true
  root rm -f "$PREFIX/bin/displaytube" "$PREFIX/share/applications/displaytube.desktop" \
             /etc/modules-load.d/displaytube-evdi.conf /etc/modprobe.d/displaytube-evdi.conf
  root rm -rf "$PREFIX/share/displaytube"
  ok "DisplayTube dosyalari kaldirildi"
  echo "EVDI, adb ve FFmpeg gibi bagimliliklar baska programlar da kullanabilecegi icin kaldirilmadi."
  echo "Telefondaki uygulama: adb uninstall com.displaytube.receiver"
  exit 0
fi

# ---------------------------------------------------------------- plan

APK=""
for a in "$HERE/DisplayTube.apk" "$HERE/../android/build/DisplayTube.apk" "$HERE/../linux-handoff/DisplayTube.apk"; do
  [ -f "$a" ] && { APK="$a"; break; }
done

echo "${B}DisplayTube $VERSION - Linux kurulumu${N}"
echo "  Dagitim: ${PRETTY_NAME:-$DISTRO_ID} ($FAMILY), kernel $KERNEL"
echo "  Ekran karti:${GPUS:- bulunamadi}"
echo
echo "Indirilip kurulacaklar (kurulu olanlar atlanir):"
echo "  - EVDI $EVDI_VERSION sanal ekran surucusu (kernel modulu, DKMS ile derlenir)"
echo "  - adb ve telefon USB izin kurallari"
echo "  - FFmpeg kutuphaneleri ve donanim H.264 kodlama surucusu (VAAPI / NVENC)"
echo "  - derleme araclari ve kernel basliklari"
echo "Sonra DisplayTube $PREFIX altina kurulur. Yonetici sifresi sorulabilir."
echo
confirm "Devam edilsin mi?" || { echo "Iptal edildi."; exit 1; }
WORK="$(mktemp -d)"
trap 'finish' EXIT

if [ "$DRY_RUN" = 0 ]; then
  say "Yonetici yetkisi"
  if [ "${SUDO[0]}" != pkexec ] && ! "${SUDO[@]}" -v; then
    problem "Yonetici yetkisi alinamadi" "Sifreyi dogru girdiginizden ve kullanicinizin sudo yetkisi oldugundan emin olun."
    exit 1
  fi
  # Uzun derlemeler sirasinda sudo zaman asimina ugramasin
  if [ "${SUDO[0]}" = sudo ]; then
    ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
  fi
fi

# ---------------------------------------------------------------- paketler

say "Paketler indiriliyor ve kuruluyor"

pkg_install() {   # pkg_install "aciklama" paket...
  local what="$1"; shift
  local rc=0
  case "$FAMILY" in
    arch)   root pacman -S --needed --noconfirm "$@" || rc=$? ;;
    debian) root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || rc=$? ;;
    fedora) root dnf install -y "$@" || rc=$? ;;
    suse)   root zypper --non-interactive install --no-recommends "$@" || rc=$? ;;
    *) rc=1 ;;
  esac
  if [ $rc -eq 0 ]; then ok "$what"; else problem "$what indirilemedi/kurulamadi ($*)" "$(net_hint)"; fi
  return $rc
}

case "$FAMILY" in
  arch)
    # Calisan kernel'in baslik paketi: /usr/lib/modules/<surum>'un sahibi + "-headers"
    KPKG="$(pacman -Qqo "/usr/lib/modules/$KERNEL" 2>/dev/null | head -n1)"
    [ -n "$KPKG" ] || KPKG=linux
    pkg_install "Derleme araclari" base-devel git pkgconf
    pkg_install "DKMS ve kernel basliklari ($KPKG-headers)" dkms "$KPKG-headers"
    pkg_install "adb ve USB kurallari" android-tools android-udev
    pkg_install "FFmpeg ve VAAPI" ffmpeg libva libdrm libnotify
    has_gpu amd && pkg_install "AMD VAAPI surucusu (Mesa)" mesa
    has_gpu intel && pkg_install "Intel VAAPI surucusu" intel-media-driver
    ;;
  debian)
    root apt-get update || problem "Paket listesi guncellenemedi (apt-get update)" "$(net_hint)"
    pkg_install "Derleme araclari" build-essential pkg-config git curl ca-certificates libdrm-dev
    pkg_install "DKMS ve kernel basliklari" dkms "linux-headers-$KERNEL"
    pkg_install "adb ve USB kurallari" adb android-sdk-platform-tools-common
    pkg_install "FFmpeg gelistirme kutuphaneleri" libavcodec-dev libavfilter-dev libavutil-dev libswscale-dev libnotify-bin
    has_gpu amd && pkg_install "AMD VAAPI surucusu (Mesa)" mesa-va-drivers
    if has_gpu intel; then
      # Kodlama destegi non-free pakette; yoksa ozgur olani dene
      if apt-cache show intel-media-va-driver-non-free >/dev/null 2>&1; then
        pkg_install "Intel VAAPI surucusu" intel-media-va-driver-non-free
      else
        pkg_install "Intel VAAPI surucusu" intel-media-va-driver
      fi
    fi
    # Debian/Ubuntu'da adb USB erisimi plugdev grubu ister
    if getent group plugdev >/dev/null && ! id -nG | tr ' ' '\n' | grep -qx plugdev; then
      root usermod -aG plugdev "$USER" && warn "plugdev grubuna eklendiniz; telefon icin oturumu kapatip acin."
    fi
    ;;
  fedora)
    pkg_install "Derleme araclari" gcc make pkgconf-pkg-config git curl libdrm-devel libnotify
    pkg_install "DKMS ve kernel basliklari" dkms "kernel-devel-$KERNEL"
    pkg_install "adb" android-tools
    if dnf repolist --enabled 2>/dev/null | grep -q rpmfusion-free; then
      pkg_install "FFmpeg gelistirme kutuphaneleri" ffmpeg-devel
      has_gpu amd && pkg_install "AMD VAAPI surucusu (freeworld)" mesa-va-drivers-freeworld
      has_gpu intel && pkg_install "Intel VAAPI surucusu" intel-media-driver
    else
      pkg_install "FFmpeg gelistirme kutuphaneleri" ffmpeg-free-devel
      warn "RPM Fusion etkin degil: Fedora'nin kendi paketlerinde H.264 kodlama kapali olabilir."
      warn "Donanim kodlama icin: https://rpmfusion.org/Configuration adresinden RPM Fusion'i etkinlestirip yukleyiciyi yeniden calistirin."
    fi
    ;;
  suse)
    pkg_install "Derleme araclari" gcc make pkg-config git curl libdrm-devel libnotify-tools
    pkg_install "DKMS ve kernel basliklari" dkms kernel-devel
    pkg_install "adb" android-tools
    pkg_install "FFmpeg gelistirme kutuphaneleri" ffmpeg-devel ||
      warn "openSUSE'de H.264 icin Packman deposu gerekebilir: https://en.opensuse.org/Additional_package_repositories#Packman"
    ;;
  *)
    problem "Bu dagitim ($DISTRO_ID) otomatik kurulumda tanimli degil" \
      "Su bilesenleri paket yoneticinizle kurun: derleme araclari (gcc, make, pkg-config), dkms, calisan kernel'in basliklari, libdrm gelistirme dosyalari, adb, FFmpeg gelistirme kutuphaneleri (libavcodec/libavfilter/libavutil/libswscale), ekran kartiniza uygun VAAPI surucusu. Sonra yukleyiciyi yeniden calistirin."
    ;;
esac

# ---------------------------------------------------------------- EVDI

say "EVDI sanal ekran surucusu"

evdi_lib_ok()    { [ -f /usr/include/evdi_lib.h ] || [ -f /usr/local/include/evdi_lib.h ]; }
evdi_module_ok() { modinfo evdi >/dev/null 2>&1; }

evdi_from_source() {
  local tgz="$WORK/evdi.tar.gz" src="$WORK/evdi-$EVDI_VERSION"
  if ! run curl -fL --retry 3 -m 120 -o "$tgz" "$EVDI_URL"; then
    problem "EVDI kaynak kodu indirilemedi ($EVDI_URL)" "$(net_hint)"
    return 1
  fi
  if [ "$DRY_RUN" = 0 ] && ! echo "$EVDI_SHA256  $tgz" | sha256sum -c --quiet - >/dev/null 2>&1; then
    problem "Indirilen EVDI dosyasi bozuk (saglama toplami tutmadi)" "Indirme yarida kesilmis ya da degistirilmis olabilir. Yukleyiciyi yeniden calistirin."
    return 1
  fi
  run tar -xzf "$tgz" -C "$WORK" || { problem "EVDI arsivi acilamadi" "Ayrintilar: $LOG"; return 1; }
  if ! evdi_lib_ok; then
    if run make -C "$src/library" && root make -C "$src/library" install PREFIX=/usr/local &&
       root install -Dm644 "$src/library/evdi_lib.h" /usr/local/include/evdi_lib.h; then
      # Bazi dagitimlar (Fedora) /usr/local/lib'i varsayilan aramaz
      { root_write /etc/ld.so.conf.d/displaytube-local.conf /usr/local/lib && root ldconfig; } ||
        warn "/usr/local/lib kutuphane yoluna eklenemedi; libevdi bulunamazsa: echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/local.conf && sudo ldconfig"
      ok "libevdi $EVDI_VERSION kuruldu"
    else
      problem "libevdi derlenemedi" "libdrm gelistirme paketinin kurulu oldugundan emin olun. Ayrintilar: $LOG"
    fi
  fi
  if ! evdi_module_ok; then
    root rm -rf "/usr/src/evdi-$EVDI_VERSION"
    if root cp -r "$src/module" "/usr/src/evdi-$EVDI_VERSION" &&
       root dkms install "evdi/$EVDI_VERSION" -k "$KERNEL"; then
      ok "EVDI kernel modulu derlendi (DKMS)"
    else
      problem "EVDI kernel modulu bu kernel ($KERNEL) icin derlenemedi" \
        "Kernel basliklarinin kurulu oldugunu kontrol edin. Kernel cok yeniyse EVDI'nin yeni surumu gerekebilir: https://github.com/DisplayLink/evdi/releases . Ayrintilar: $LOG ve /var/lib/dkms/evdi/"
    fi
  fi
}

if evdi_lib_ok && evdi_module_ok; then
  ok "EVDI zaten kurulu $(cat /sys/devices/evdi/version 2>/dev/null)"
elif [ "$FAMILY" = arch ]; then
  # Arch'ta AUR paketi: pacman ile izlenir, kernel guncellemesinde DKMS yeniden derler
  if command -v paru >/dev/null 2>&1; then run paru -S --needed --noconfirm --skipreview evdi-dkms
  elif command -v yay >/dev/null 2>&1; then run yay -S --needed --noconfirm --answerdiff None --answerclean None evdi-dkms
  else
    run git clone --depth 1 https://aur.archlinux.org/evdi-dkms.git "$WORK/evdi-dkms" &&
      (cd "$WORK/evdi-dkms" && run makepkg -si --needed --noconfirm)
  fi
  if [ "$DRY_RUN" = 1 ] || { evdi_lib_ok && evdi_module_ok; }; then ok "evdi-dkms (AUR) kuruldu"
  else
    problem "EVDI (AUR evdi-dkms) indirilemedi/derlenemedi" \
      "$(net_hint) Elle: git clone https://aur.archlinux.org/evdi-dkms.git && cd evdi-dkms && makepkg -si"
  fi
else
  evdi_from_source
fi

# Acilista yuklensin ve bir sanal ekran cihazi hazir olsun (sunucu root'suz calisir)
if root_write /etc/modules-load.d/displaytube-evdi.conf evdi &&
   root_write /etc/modprobe.d/displaytube-evdi.conf "options evdi initial_device_count=1"; then
  ok "EVDI acilista otomatik yuklenecek"
else
  problem "EVDI'nin acilista yuklenme ayari yazilamadi" \
    "Elle: echo evdi | sudo tee /etc/modules-load.d/displaytube-evdi.conf; echo 'options evdi initial_device_count=1' | sudo tee /etc/modprobe.d/displaytube-evdi.conf"
fi
if [ "$DRY_RUN" = 1 ]; then :
elif [ -d /sys/devices/evdi ]; then
  # Modul zaten yuklu (calisan bir yayin olabilir): kaldirmadan cihaz ekle
  if ls -d /sys/devices/platform/evdi.* >/dev/null 2>&1; then ok "EVDI yuklu, sanal ekran cihazi hazir"
  elif echo 1 | "${SUDO[@]}" tee /sys/devices/evdi/add >/dev/null; then ok "Sanal ekran cihazi eklendi"
  else problem "Sanal ekran cihazi eklenemedi" "Bilgisayari yeniden baslatin."
  fi
elif evdi_module_ok; then
  if root modprobe evdi initial_device_count=1; then ok "EVDI modulu yuklendi"
  else
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
      problem "EVDI modulu yuklenemedi: Secure Boot imzasiz modulu reddediyor" \
        "DKMS anahtarini MOK'a kaydedin (sudo mokutil --import /var/lib/dkms/mok.pub, yeniden baslatip onaylayin) ya da Secure Boot'u kapatin."
    else
      problem "EVDI modulu yuklenemedi" "Bilgisayari yeniden baslatip tekrar deneyin. Ayrintilar: sudo dmesg | grep -i evdi"
    fi
  fi
fi

# ---------------------------------------------------------------- DisplayTube

say "DisplayTube derleniyor"
BUILD="$WORK/server"
cp -r "$HERE/server" "$BUILD"
if run make -C "$BUILD" APK_PATH="$PREFIX/share/displaytube/DisplayTube.apk"; then
  ok "displaytube derlendi"
else
  problem "DisplayTube derlenemedi" "Genelde eksik FFmpeg gelistirme paketi ya da libevdi'den kaynaklanir (yukaridaki hatalara bakin). Ayrintilar: $LOG"
fi

say "Dosyalar yerlestiriliyor"
if [ "$DRY_RUN" = 1 ] || [ -x "$BUILD/displaytube" ]; then
  if root install -Dm755 "$BUILD/displaytube" "$PREFIX/bin/displaytube"; then ok "$PREFIX/bin/displaytube"
  else problem "Program $PREFIX/bin altina kopyalanamadi" "Yonetici yetkisini ve diskte yer oldugunu kontrol edin. Ayrintilar: $LOG"
  fi
fi
if [ -n "$APK" ]; then
  if root install -Dm644 "$APK" "$PREFIX/share/displaytube/DisplayTube.apk"; then ok "Android uygulamasi (APK)"
  else problem "Android uygulamasi (APK) kopyalanamadi" "Telefona elle kurabilirsiniz: adb install -r \"$APK\""
  fi
else
  warn "DisplayTube.apk paketin icinde bulunamadi; telefona uygulamayi elle kurmaniz gerekecek."
fi
root install -Dm644 "$HERE/displaytube.desktop" "$PREFIX/share/applications/displaytube.desktop" &&
  ok "Uygulama menusu girdisi" || warn "Uygulama menusu girdisi eklenemedi (DisplayTube yine de calisir)"
mkdir -p "$HOME/.config/systemd/user"
sed "s|@PREFIX@|$PREFIX|g" "$HERE/displaytube.service" > "$WORK/displaytube.service"
if run install -Dm644 "$WORK/displaytube.service" "$HOME/.config/systemd/user/displaytube.service" &&
   run systemctl --user daemon-reload; then ok "systemd kullanici servisi (displaytube.service)"
else problem "systemd kullanici servisi kurulamadi" "DisplayTube'u elle baslatabilirsiniz: $PREFIX/bin/displaytube"
fi

# ---------------------------------------------------------------- denetim

say "Kurulum denetleniyor"
if [ "$DRY_RUN" = 1 ]; then
  printf '    [deneme] %s --check\n' "$PREFIX/bin/displaytube"
elif [ -x "$PREFIX/bin/displaytube" ]; then
  while IFS= read -r line; do
    log "check: $line"
    case "$line" in
      "OK "*) ok "${line#OK }" ;;
      "UYARI "*) warn "${line#UYARI }" ;;
      "HATA evdi"*) problem "Sanal ekran hazir degil: ${line#HATA evdi }" "Bilgisayari yeniden baslatin; sorun surerse yukleyiciyi yeniden calistirin." ;;
      "HATA adb"*) problem "adb bulunamadi" "adb paketini kurun (Arch: android-tools, Debian/Ubuntu: adb, Fedora: android-tools)." ;;
      "HATA kodlayici"*) problem "Calisan bir H.264 kodlayici yok" "Ekran kartiniz icin VAAPI surucusunu (AMD/Intel) ya da NVIDIA surucusunu kurun; yazilim kodlama icin FFmpeg'in libx264 destekli olmasi gerekir." ;;
      "HATA "*) problem "${line#HATA }" "Ayrintilar: $LOG" ;;
    esac
  done < <("$PREFIX/bin/displaytube" --check 2>>"$LOG")
else
  problem "Kurulu program bulunamadi ($PREFIX/bin/displaytube)" "Yukaridaki derleme/kopyalama hatalarini giderip yukleyiciyi yeniden calistirin."
fi

# ---------------------------------------------------------------- otomatik baslatma

if [ ${#PROBLEMS[@]} -eq 0 ]; then
  if [ "$AUTOSTART" = ask ]; then
    confirm "DisplayTube oturum acilisinda otomatik baslasin mi?" && AUTOSTART=yes || AUTOSTART=no
  fi
  if [ "$AUTOSTART" = yes ]; then
    run systemctl --user enable displaytube.service && ok "Acilista baslatma acik"
  fi
  if ss -ltn 2>/dev/null | grep -q '127.0.0.1:27183 '; then
    warn "27183 portunda zaten bir DisplayTube calisiyor; servis simdi baslatilmadi (yayini kesmemek icin)."
  elif run systemctl --user restart displaytube.service; then
    ok "DisplayTube baslatildi"
  else
    problem "Servis baslatilamadi" "journalctl --user -u displaytube.service ciktisina bakin."
  fi
fi
