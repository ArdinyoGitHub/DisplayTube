#!/usr/bin/env bash
# DisplayTube Linux surum paketini olusturur: release/DisplayTube-v<surum>-linux.tar.gz
# Icerik: install.sh, server/ (kaynak; kurulumda derlenir), DisplayTube.apk, servis ve menu dosyalari, belgeler.
# EVDI, FFmpeg ve adb paketlenmez; yukleyici indirir (THIRD-PARTY-NOTICES.md).
set -euo pipefail
VERSION="${1:-0.3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="DisplayTube-v$VERSION-linux"
OUT="$ROOT/release/$NAME"
APK="$ROOT/android/build/DisplayTube.apk"
[ -f "$APK" ] || { echo "APK yok: $APK (android/build.sh ile derleyin)"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/server"
cp "$ROOT/linux/install.sh" "$ROOT/linux/displaytube.service" "$ROOT/linux/displaytube.desktop" "$OUT/"
cp "$ROOT/linux/server/displaytube.c" "$ROOT/linux/server/Makefile" "$OUT/server/"
cp "$APK" "$OUT/DisplayTube.apk"
cp "$ROOT/linux/README.md" "$OUT/README.md"
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY-NOTICES.md" "$OUT/"
chmod +x "$OUT/install.sh"
tar -C "$ROOT/release" -czf "$ROOT/release/$NAME.tar.gz" "$NAME"
echo "Hazir: release/$NAME.tar.gz"
