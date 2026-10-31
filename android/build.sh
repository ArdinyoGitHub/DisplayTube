#!/usr/bin/env bash
# DisplayTube alici uygulamasini Gradle olmadan, dogrudan Android SDK araclariyla derler
# (build.ps1'in Linux karsiligi): javac -> d8 -> aapt2 -> zipalign -> apksigner.
#
# Gereken: JDK 17 (javac, keytool) ve Android SDK: platforms;android-34, build-tools;34.0.0
#   ANDROID_HOME (ya da ANDROID_SDK_ROOT) SDK klasorunu gostermeli.
# Kullanim: ./build.sh            -> build/DisplayTube.apk
#           ./build.sh --install  -> ayrica bagli telefona kur, adb reverse kur, uygulamayi ac
set -euo pipefail

cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
BT="$SDK/build-tools/34.0.0"
JAR="$SDK/platforms/android-34/android.jar"
OUT=build

for p in "$BT/d8" "$BT/aapt2" "$BT/zipalign" "$BT/apksigner" "$JAR"; do
  [ -e "$p" ] || { echo "Eksik: $p (sdkmanager 'platforms;android-34' 'build-tools;34.0.0')"; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"

echo "==> javac"
javac -nowarn -source 8 -target 8 -bootclasspath "$JAR" -encoding UTF-8 -d "$OUT/classes" $(find src -name '*.java')

echo "==> d8"
"$BT/d8" --release --min-api 26 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')

echo "==> aapt2"
"$BT/aapt2" compile --dir res -o "$OUT/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml -R "$OUT/res.zip" -o "$OUT/unaligned.apk"
(cd "$OUT/dex" && zip -q ../unaligned.apk classes.dex)

echo "==> zipalign + apksigner"
"$BT/zipalign" -f 4 "$OUT/unaligned.apk" "$OUT/aligned.apk"
[ -f debug.keystore ] || keytool -genkeypair -keystore debug.keystore -storepass android -alias androiddebugkey \
  -keypass android -dname 'CN=Android Debug,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000
"$BT/apksigner" sign --ks debug.keystore --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/DisplayTube.apk" "$OUT/aligned.apk"
echo "Hazir: $OUT/DisplayTube.apk"

if [ "${1:-}" = "--install" ]; then
  adb install -r "$OUT/DisplayTube.apk"
  adb reverse tcp:27183 tcp:27183
  adb shell am start -n com.displaytube.receiver/.MainActivity
fi
