#!/usr/bin/env bash
# DisplayTube alici uygulamasini Gradle olmadan, dogrudan Android SDK araclariyla derler
# (build.ps1'in Linux karsiligi).
#   APK: javac -> d8 -> aapt2 -> zipalign -> apksigner (debug anahtari)
#   AAB: javac -> d8 -> aapt2 (--proto-format) -> bundletool build-bundle -> jarsigner (yukleme anahtari)
#
# Gereken: JDK 17 (javac, keytool, jarsigner) ve Android SDK: platforms;android-36, build-tools;36.0.0
#   ANDROID_HOME (ya da ANDROID_SDK_ROOT) SDK klasorunu gostermeli.
#   AAB icin ayrica bundletool: BUNDLETOOL=/yol/bundletool-all.jar (varsayilan: ../tools/bundletool.jar)
#
# Kullanim: ./build.sh            -> build/DisplayTube.apk (debug imzali; PC paketine giren dosya)
#           ./build.sh --install  -> ayrica bagli telefona kur, adb reverse kur, uygulamayi ac
#           ./build.sh --aab      -> build/DisplayTube.aab (Google Play'e yuklenecek dosya)
#
# AAB imzalama (Play "yukleme anahtari"). Anahtar ve sifreler ASLA depoya girmez; ortam degiskeniyle verilir:
#   UPLOAD_KEYSTORE=/guvenli/yer/upload.jks UPLOAD_KEY_ALIAS=upload \
#   UPLOAD_STORE_PASSWORD=... UPLOAD_KEY_PASSWORD=... ./build.sh --aab
# UPLOAD_KEYSTORE verilmezse AAB imzasiz uretilir (Play Console imzasiz AAB'yi kabul etmez).
set -euo pipefail

cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
API=36
BT="$SDK/build-tools/36.0.0"
JAR="$SDK/platforms/android-$API/android.jar"
OUT=build
MODE="${1:-}"

for p in "$BT/d8" "$BT/aapt2" "$BT/zipalign" "$BT/apksigner" "$JAR"; do
  [ -e "$p" ] || { echo "Eksik: $p (sdkmanager 'platforms;android-$API' 'build-tools;36.0.0')"; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"

echo "==> javac"
javac -nowarn -source 8 -target 8 -bootclasspath "$JAR" -encoding UTF-8 -d "$OUT/classes" $(find src -name '*.java')

echo "==> d8"
"$BT/d8" --release --min-api 26 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

echo "==> aapt2 compile"
"$BT/aapt2" compile --dir res -o "$OUT/res.zip"

if [ "$MODE" = "--aab" ]; then
  BUNDLETOOL="${BUNDLETOOL:-../tools/bundletool.jar}"
  [ -f "$BUNDLETOOL" ] || { echo "Eksik: bundletool ($BUNDLETOOL). https://github.com/google/bundletool/releases adresinden"
                            echo "bundletool-all-*.jar indirip BUNDLETOOL=/yol/bundletool.jar verin."; exit 1; }

  echo "==> aapt2 link (proto)"
  "$BT/aapt2" link --proto-format -I "$JAR" --manifest AndroidManifest.xml -R "$OUT/res.zip" -o "$OUT/proto.zip"

  echo "==> base modulu"
  # bundletool modul duzeni: manifest/AndroidManifest.xml, dex/classes.dex, res/..., resources.pb
  mkdir -p "$OUT/base/manifest" "$OUT/base/dex"
  (cd "$OUT/base" && unzip -q ../proto.zip)
  mv "$OUT/base/AndroidManifest.xml" "$OUT/base/manifest/AndroidManifest.xml"
  cp "$OUT/dex/classes.dex" "$OUT/base/dex/classes.dex"
  (cd "$OUT/base" && zip -qr ../base.zip .)

  echo "==> bundletool build-bundle"
  java -jar "$BUNDLETOOL" build-bundle --modules="$OUT/base.zip" --output="$OUT/DisplayTube.aab"
  java -jar "$BUNDLETOOL" validate --bundle="$OUT/DisplayTube.aab" > /dev/null

  if [ -n "${UPLOAD_KEYSTORE:-}" ]; then
    echo "==> jarsigner (yukleme anahtari)"
    : "${UPLOAD_STORE_PASSWORD:?UPLOAD_STORE_PASSWORD gerekli}" "${UPLOAD_KEY_ALIAS:=upload}"
    export UPLOAD_KEY_PASSWORD="${UPLOAD_KEY_PASSWORD:-$UPLOAD_STORE_PASSWORD}"
    jarsigner -keystore "$UPLOAD_KEYSTORE" -storepass:env UPLOAD_STORE_PASSWORD -keypass:env UPLOAD_KEY_PASSWORD \
      -sigalg SHA256withRSA -digestalg SHA-256 "$OUT/DisplayTube.aab" "$UPLOAD_KEY_ALIAS" > /dev/null
    jarsigner -verify "$OUT/DisplayTube.aab" > /dev/null
    echo "Hazir (imzali): $OUT/DisplayTube.aab"
  else
    echo "Hazir (IMZASIZ, Play'e yuklemek icin UPLOAD_KEYSTORE verin): $OUT/DisplayTube.aab"
  fi
  exit 0
fi

echo "==> aapt2 link"
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml -R "$OUT/res.zip" -o "$OUT/unaligned.apk"
(cd "$OUT/dex" && zip -q ../unaligned.apk classes.dex)

echo "==> zipalign + apksigner"
"$BT/zipalign" -f 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"
[ -f debug.keystore ] || keytool -genkeypair -keystore debug.keystore -storepass android -alias androiddebugkey \
  -keypass android -dname 'CN=Android Debug,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000
"$BT/apksigner" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/DisplayTube.apk" "$OUT/aligned.apk"
echo "Hazir: $OUT/DisplayTube.apk"

if [ "$MODE" = "--install" ]; then
  adb install -r "$OUT/DisplayTube.apk"
  adb reverse tcp:27183 tcp:27183
  adb shell am start -n com.displaytube.receiver/.MainActivity
fi
