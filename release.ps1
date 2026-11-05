<#
DisplayTube surum paketini olusturur: release\DisplayTube-v<surum>-win-x64.zip

Icerik:
  DisplayTube.exe        bildirim alani uygulamasi + yakalama motoru (self-contained, .NET gerekmez)
  DisplayTube.apk        Android alici (telefona otomatik kurulur)
  driver\                Virtual Display Driver (MIT)
  README.md, LICENSE, THIRD-PARTY-NOTICES.md
adb paketlenmez (Android SDK lisansi); kurulum programi (ya da uygulama ilk calismada) kullanicinin izniyle indirir.

Kullanim:
  .\release.ps1 -Version 0.4.0                   # zip
  .\release.ps1 -Version 0.4.0 -Installer        # zip + release\DisplayTube-Setup-v0.4.0.exe (Inno Setup 6 gerekir)
  .\release.ps1 -Apk yol\DisplayTube.apk ...     # APK'yi derlemek yerine hazir dosyayi kullan (CI)
#>
param([string]$Version = '0.4.0', [string]$Apk, [switch]$Installer)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Name = "DisplayTube-v$Version-win-x64"
$Out = Join-Path $Root "release\$Name"
$Zip = Join-Path $Root "release\$Name.zip"

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "$what basarisiz (kod $LASTEXITCODE)" } }

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force "$Out\driver" | Out-Null

Step 'Android uygulamasi'
if (-not $Apk) {
    & (Join-Path $Root 'android\build.ps1'); Check 'android\build.ps1'
    $Apk = Join-Path $Root 'android\build\DisplayTube.apk'
}
Copy-Item $Apk (Join-Path $Out 'DisplayTube.apk')

Step 'Windows uygulamasi (self-contained, tek dosya)'
$pub = Join-Path $Root 'release\publish'
dotnet publish (Join-Path $Root 'pc\DisplayTubeApp') -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
    -p:DebugType=None -p:Version=$Version -nologo -v q -o $pub
Check 'dotnet publish'
Copy-Item (Join-Path $pub 'DisplayTube.exe') $Out

Step 'Surucu ve belgeler'
$vdd = Join-Path $Root 'VirtualDisplayDriver'
foreach ($f in 'MttVDD.inf', 'MttVDD.dll', 'mttvdd.cat', 'Virtual_Display_Driver.cer', 'vdd_settings.xml') {
    Copy-Item (Join-Path $vdd $f) "$Out\driver"
}
foreach ($f in 'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md') { Copy-Item (Join-Path $Root $f) $Out }

Step 'Zip'
if (Test-Path $Zip) { Remove-Item $Zip }
Compress-Archive -Path "$Out\*" -DestinationPath $Zip
Get-ChildItem $Out -Recurse -File | ForEach-Object { '{0,-40} {1,10:N0}' -f $_.FullName.Substring($Out.Length + 1), $_.Length }
Write-Host ("Hazir: {0} ({1:N1} MB)" -f $Zip, ((Get-Item $Zip).Length / 1MB)) -ForegroundColor Green

if ($Installer) {
    Step 'Kurulum programi (Inno Setup)'
    $iscc = @((Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
              "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
              "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
            Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 bulunamadi: https://jrsoftware.org/isdl.php (ya da: winget install JRSoftware.InnoSetup)' }
    & $iscc /Qp "/DAppVersion=$Version" "/DSourceDir=$Out" (Join-Path $Root 'installer\DisplayTube.iss')
    Check 'ISCC'
    $setup = Join-Path $Root "release\DisplayTube-Setup-v$Version.exe"
    Write-Host ("Hazir: {0} ({1:N1} MB)" -f $setup, ((Get-Item $setup).Length / 1MB)) -ForegroundColor Green
}
