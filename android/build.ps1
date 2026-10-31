<#
DisplayTube alici uygulamasini Gradle olmadan, dogrudan Android SDK araclariyla derler:
javac -> d8 -> aapt2 -> zipalign -> apksigner. Ek indirme gerekmez.

Gereken: tools\jdk (JDK 17) ve tools\android-sdk (platforms;android-34, build-tools;34.0.0).

Kullanim:
  .\build.ps1             # build\DisplayTube.apk uret
  .\build.ps1 -Install    # ayrica bagli telefona kur ve baslat
#>
param([switch]$Install)

# Araclar stderr'e bilgi yazar; PowerShell 5.1 bunu hata sanmasin. Hatalar Run icinde cikis koduyla yakalaniyor.
$ErrorActionPreference = 'Continue'
$Root  = Split-Path $PSScriptRoot
$Jdk   = Get-ChildItem (Join-Path $Root 'tools\jdk') -Directory | Select-Object -First 1 -ExpandProperty FullName
$Sdk   = Join-Path $Root 'tools\android-sdk'
$Bt    = Join-Path $Sdk 'build-tools\34.0.0'
$Jar   = Join-Path $Sdk 'platforms\android-34\android.jar'
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
Run "$Bt\aapt2.exe" link -I $Jar --manifest (Join-Path $PSScriptRoot 'AndroidManifest.xml') -o "$Out\unaligned.apk"

# classes.dex'i APK'ya ekle
Add-Type -AssemblyName System.IO.Compression.FileSystem
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
