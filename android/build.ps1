<#
DisplayTube alici uygulamasini Gradle olmadan, dogrudan Android SDK araclariyla derler:
  APK: javac -> d8 -> aapt2 -> zipalign -> apksigner (debug anahtari)
  AAB: javac -> d8 -> aapt2 (--proto-format) -> bundletool build-bundle -> jarsigner (yukleme anahtari)

Gereken: tools\jdk (JDK 17) ve tools\android-sdk (platforms;android-36, build-tools;36.0.0).
AAB icin ayrica tools\bundletool.jar (https://github.com/google/bundletool/releases, bundletool-all-*.jar).

Kullanim:
  .\build.ps1             # build\DisplayTube.apk uret (debug imzali; PC paketine giren dosya)
  .\build.ps1 -Install    # ayrica bagli telefona kur ve baslat
  .\build.ps1 -Aab        # build\DisplayTube.aab uret (Google Play'e yuklenecek dosya)

AAB imzalama (Play "yukleme anahtari"). Anahtar ve sifreler ASLA depoya girmez; ortam degiskeniyle verilir:
  $env:UPLOAD_KEYSTORE='C:\guvenli\upload.jks'; $env:UPLOAD_KEY_ALIAS='upload'
  $env:UPLOAD_STORE_PASSWORD='...'; $env:UPLOAD_KEY_PASSWORD='...'
  .\build.ps1 -Aab
UPLOAD_KEYSTORE yoksa AAB imzasiz uretilir (Play Console imzasiz AAB'yi kabul etmez).
#>
param([switch]$Install, [switch]$Aab)

# Araclar stderr'e bilgi yazar; PowerShell 5.1 bunu hata sanmasin. Hatalar Run icinde cikis koduyla yakalaniyor.
$ErrorActionPreference = 'Continue'
$Root  = Split-Path $PSScriptRoot
$Jdk   = Get-ChildItem (Join-Path $Root 'tools\jdk') -Directory | Select-Object -First 1 -ExpandProperty FullName
$Sdk   = Join-Path $Root 'tools\android-sdk'
$Bt    = Join-Path $Sdk 'build-tools\36.0.0'
$Jar   = Join-Path $Sdk 'platforms\android-36\android.jar'
$Out   = Join-Path $PSScriptRoot 'build'
$env:JAVA_HOME = $Jdk
$env:PATH = "$Jdk\bin;$env:PATH"

function Run($exe) {
    & $exe @args
    if ($LASTEXITCODE -ne 0) { throw "$(Split-Path $exe -Leaf) basarisiz (kod $LASTEXITCODE)" }
}

foreach ($p in @($Jdk, $Bt, $Jar)) { if (-not $p -or -not (Test-Path $p)) { throw "Eksik: $p" } }

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force "$Out\classes", "$Out\dex" | Out-Null

Write-Host '==> javac'
$sources = Get-ChildItem (Join-Path $PSScriptRoot 'src') -Recurse -Filter *.java | ForEach-Object FullName
Run "$Jdk\bin\javac.exe" -nowarn -source 8 -target 8 -bootclasspath $Jar -encoding UTF-8 -d "$Out\classes" @sources

Write-Host '==> d8'
$classes = Get-ChildItem "$Out\classes" -Recurse -Filter *.class | ForEach-Object FullName
Run "$Bt\d8.bat" --release --min-api 26 --lib $Jar --output "$Out\dex" @classes

Write-Host '==> aapt2'
# Kaynaklar (uygulama simgesi) derlenip baglanir; kodda R sinifi kullanilmiyor.
Run "$Bt\aapt2.exe" compile --dir (Join-Path $PSScriptRoot 'res') -o "$Out\res.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($Aab) {
    $bundletool = if ($env:BUNDLETOOL) { $env:BUNDLETOOL } else { Join-Path $Root 'tools\bundletool.jar' }
    if (-not (Test-Path $bundletool)) {
        throw "Eksik: $bundletool. https://github.com/google/bundletool/releases adresinden bundletool-all-*.jar indirip buraya koyun."
    }
    Run "$Bt\aapt2.exe" link --proto-format -I $Jar --manifest (Join-Path $PSScriptRoot 'AndroidManifest.xml') -R "$Out\res.zip" -o "$Out\proto.zip"

    Write-Host '==> base modulu'
    # bundletool modul duzeni: manifest\AndroidManifest.xml, dex\classes.dex, res\..., resources.pb
    $base = Join-Path $Out 'base'
    [IO.Compression.ZipFile]::ExtractToDirectory("$Out\proto.zip", $base)
    New-Item -ItemType Directory -Force "$base\manifest", "$base\dex" | Out-Null
    Move-Item "$base\AndroidManifest.xml" "$base\manifest\AndroidManifest.xml"
    Copy-Item "$Out\dex\classes.dex" "$base\dex\classes.dex"
    # Zip girdileri '/' ayiraciyla yazilmali (ZipFile.CreateFromDirectory eski .NET'te '\' yazabilir)
    $zip = [IO.Compression.ZipFile]::Open("$Out\base.zip", 'Create')
    Get-ChildItem $base -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $rel) | Out-Null
    }
    $zip.Dispose()

    Write-Host '==> bundletool build-bundle'
    Run "$Jdk\bin\java.exe" -jar $bundletool build-bundle "--modules=$Out\base.zip" "--output=$Out\DisplayTube.aab"
    Run "$Jdk\bin\java.exe" -jar $bundletool validate "--bundle=$Out\DisplayTube.aab" | Out-Null

    if ($env:UPLOAD_KEYSTORE) {
        Write-Host '==> jarsigner (yukleme anahtari)'
        if (-not $env:UPLOAD_STORE_PASSWORD) { throw 'UPLOAD_STORE_PASSWORD gerekli' }
        if (-not $env:UPLOAD_KEY_PASSWORD) { $env:UPLOAD_KEY_PASSWORD = $env:UPLOAD_STORE_PASSWORD }
        $alias = if ($env:UPLOAD_KEY_ALIAS) { $env:UPLOAD_KEY_ALIAS } else { 'upload' }
        Run "$Jdk\bin\jarsigner.exe" -keystore $env:UPLOAD_KEYSTORE -storepass:env UPLOAD_STORE_PASSWORD -keypass:env UPLOAD_KEY_PASSWORD `
            -sigalg SHA256withRSA -digestalg SHA-256 "$Out\DisplayTube.aab" $alias | Out-Null
        Run "$Jdk\bin\jarsigner.exe" -verify "$Out\DisplayTube.aab" | Out-Null
        Write-Host "Hazir (imzali): $Out\DisplayTube.aab" -ForegroundColor Green
    } else {
        Write-Host "Hazir (IMZASIZ, Play'e yuklemek icin UPLOAD_KEYSTORE verin): $Out\DisplayTube.aab" -ForegroundColor Yellow
    }
    return
}

Run "$Bt\aapt2.exe" link -I $Jar --manifest (Join-Path $PSScriptRoot 'AndroidManifest.xml') -R "$Out\res.zip" -o "$Out\unaligned.apk"

# classes.dex'i APK'ya ekle
$zip = [IO.Compression.ZipFile]::Open("$Out\unaligned.apk", 'Update')
[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$Out\dex\classes.dex", 'classes.dex') | Out-Null
$zip.Dispose()

Write-Host '==> zipalign + apksigner'
Run "$Bt\zipalign.exe" -f 4 "$Out\unaligned.apk" "$Out\aligned.apk"
$ks = Join-Path $PSScriptRoot 'debug.keystore'
if (-not (Test-Path $ks)) {
    Run "$Jdk\bin\keytool.exe" -genkeypair -keystore $ks -storepass android -alias androiddebugkey -keypass android `
        -dname 'CN=Android Debug,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000
}
Run "$Bt\apksigner.bat" sign --ks $ks --ks-pass pass:android --key-pass pass:android --out "$Out\DisplayTube.apk" "$Out\aligned.apk"
Write-Host "Hazir: $Out\DisplayTube.apk" -ForegroundColor Green

if ($Install) {
    $adb = @((Join-Path $Sdk 'platform-tools\adb.exe'), 'C:\platform-tools\adb.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
    Run $adb install -r "$Out\DisplayTube.apk"
    Run $adb reverse tcp:27183 tcp:27183
    Run $adb shell am start -n com.displaytube.receiver/.MainActivity
}
