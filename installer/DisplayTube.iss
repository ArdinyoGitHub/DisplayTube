; DisplayTube Windows kurulum programi (Inno Setup 6.3+)
;
; Derleme: release.ps1 -Installer  (ya da: ISCC /DAppVersion=0.4.0 /DSourceDir=..\release\DisplayTube-v0.4.0-win-x64 DisplayTube.iss)
; SourceDir klasorunde olmasi gerekenler: DisplayTube.exe, DisplayTube.apk, driver\*, README.md, LICENSE, THIRD-PARTY-NOTICES.md
;
; Kurulumda yapilanlar:
;  - Program dosyalari {app} klasorune kopyalanir. DisplayTube.exe self-contained .NET 8 ile derlendigi icin
;    ayrica .NET kurulmasi gerekmez.
;  - Android platform-tools (adb), Google'in lisansi geregi pakete konmaz; kullanici secerse kurulum sirasinda
;    dl.google.com'dan indirilip {app}\platform-tools klasorune acilir.
;  - Virtual Display Driver (sanal ekran) kurulur.
;  - Secilen kurulum dili {app}\language.txt dosyasina yazilir; program arayuzu bu dili kullanir
;    (varsayilan Ingilizce, Turkce ikinci secenek).
;  - Bir adim basarisiz olursa kullaniciya ne oldugu ve ne yapabilecegi bildirilir.

#ifndef AppVersion
  #define AppVersion "0.4.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\release\DisplayTube-v" + AppVersion + "-win-x64"
#endif
#define AdbUrl "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"

[Setup]
AppId={{6A1F3C52-8E0B-4C2A-9D47-3B5E2F1D7A90}
AppName=DisplayTube
AppVersion={#AppVersion}
AppVerName=DisplayTube {#AppVersion}
AppPublisher=DisplayTube
AppPublisherURL=https://github.com/ArdinyoGitHub/DisplayTube
AppSupportURL=https://github.com/ArdinyoGitHub/DisplayTube/issues
DefaultDirName={autopf}\DisplayTube
DefaultGroupName=DisplayTube
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 2004 (build 19041) ve ustu
MinVersion=10.0.19041
OutputDir=..\release
OutputBaseFilename=DisplayTube-Setup-v{#AppVersion}
SetupIconFile=..\pc\DisplayTubeApp\app.ico
UninstallDisplayIcon={app}\DisplayTube.exe
LicenseFile=..\LICENSE
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
; Dil secimi: ilk acilista sorulur, varsayilan Ingilizce (sistem diline bakilmaz)
ShowLanguageDialog=yes
LanguageDetectionMethod=none
; Program calisiyorsa kurulum/kaldirma once kapatmasini ister (Program.cs'teki tekil calisma mutex'i)
AppMutex=DisplayTube.App.SingleInstance
CloseApplications=yes
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[CustomMessages]
english.TaskAdb=Download Android platform tools (adb) from Google (about 15 MB, needed to talk to the phone over USB)
turkish.TaskAdb=Android platform araçlarını (adb) Google'dan indir (yaklaşık 15 MB, telefonla USB üzerinden konuşmak için gerekli)
english.TaskDesktop=Create a desktop shortcut
turkish.TaskDesktop=Masaüstü kısayolu oluştur
english.DownloadFailed=Android platform tools could not be downloaded:%n%n%1%n%nCheck your internet connection.%n%nRetry? Choose No to continue without them; DisplayTube will offer to download them on first start.
turkish.DownloadFailed=Android platform araçları indirilemedi:%n%n%1%n%nİnternet bağlantınızı kontrol edin.%n%nTekrar denensin mi? Hayır derseniz kurulum onlarsız devam eder; DisplayTube ilk açılışta indirmeyi önerir.
english.StatusAdb=Extracting Android platform tools...
turkish.StatusAdb=Android platform araçları açılıyor...
english.StatusDriver=Installing the virtual display driver...
turkish.StatusDriver=Sanal ekran sürücüsü kuruluyor...
english.AdbFailed=Android platform tools could not be extracted (code %1). DisplayTube will offer to download them on first start.
turkish.AdbFailed=Android platform araçları açılamadı (kod %1). DisplayTube ilk açılışta indirmeyi önerir.
english.DriverFailed=The virtual display driver could not be installed (code %1). DisplayTube will try again on first start. If it keeps failing, restart the computer and run setup again.
turkish.DriverFailed=Sanal ekran sürücüsü kurulamadı (kod %1). DisplayTube ilk açılışta yeniden dener. Sorun sürerse bilgisayarı yeniden başlatıp kurulumu tekrar çalıştırın.
english.ProblemsTitle=Setup finished with problems:
turkish.ProblemsTitle=Kurulum bazı sorunlarla tamamlandı:
english.ProblemsLogs=Details:%n  Setup log: %1%n  DisplayTube log: %2
turkish.ProblemsLogs=Ayrıntılar:%n  Kurulum günlüğü: %1%n  DisplayTube günlüğü: %2

[Tasks]
Name: "adb"; Description: "{cm:TaskAdb}"
Name: "desktopicon"; Description: "{cm:TaskDesktop}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\DisplayTube.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\DisplayTube.apk"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\driver\*"; DestDir: "{app}\driver"; Flags: ignoreversion recursesubdirs
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD-PARTY-NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\DisplayTube"; Filename: "{app}\DisplayTube.exe"
Name: "{autodesktop}\DisplayTube"; Filename: "{app}\DisplayTube.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\DisplayTube.exe"; Description: "{cm:LaunchProgram,DisplayTube}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; Kendi adb sunucumuzu kapat ki platform-tools klasoru silinebilsin
Filename: "{app}\platform-tools\adb.exe"; Parameters: "kill-server"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillAdb"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\platform-tools"
Type: files; Name: "{app}\language.txt"

[Code]
var
  DownloadPage: TDownloadWizardPage;
  AdbDownloaded: Boolean;
  Problems: String;

procedure AddProblem(const Msg: String);
begin
  Log('PROBLEM: ' + Msg);
  Problems := Problems + #13#10 + '- ' + Msg;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage(SetupMessage(msgWizardPreparing), SetupMessage(msgPreparingDesc), nil);
end;

{ adb, "Hazir" sayfasindan sonra indirilir; hata olursa kullaniciya tekrar deneme ya da atlama secenegi sunulur. }
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpReady) and WizardIsTaskSelected('adb') then
  begin
    AdbDownloaded := False;
    DownloadPage.Clear;
    DownloadPage.Add('{#AdbUrl}', 'platform-tools.zip', '');
    DownloadPage.Show;
    try
      while not AdbDownloaded do
      begin
        try
          DownloadPage.Download;
          AdbDownloaded := True;
        except
          if DownloadPage.AbortedByUser then
            Break;
          if SuppressibleMsgBox(FmtMessage(CustomMessage('DownloadFailed'), [GetExceptionMessage]),
                                mbError, MB_YESNO, IDNO) <> IDYES then
            Break;
        end;
      end;
    finally
      DownloadPage.Hide;
    end;
    if not AdbDownloaded then
      Log('adb indirilmedi; program ilk acilista indirmeyi onerecek');
  end;
end;

procedure InstallAdb;
var
  Code: Integer;
  AdbExe, Zip: String;
begin
  WizardForm.StatusLabel.Caption := CustomMessage('StatusAdb');
  AdbExe := ExpandConstant('{app}\platform-tools\adb.exe');
  Zip := ExpandConstant('{tmp}\platform-tools.zip');
  { Guncellemede eski adb calisiyorsa dosyalar kilitli olur }
  if FileExists(AdbExe) then
    Exec(AdbExe, 'kill-server', '', SW_HIDE, ewWaitUntilTerminated, Code);
  DelTree(ExpandConstant('{app}\platform-tools'), True, True, True);
  { Zip'in icinde "platform-tools" klasoru var; uygulama klasorunun altina acilir }
  if not Exec('powershell.exe',
              '-NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath ''' + Zip +
              ''' -DestinationPath ''' + ExpandConstant('{app}') + ''' -Force"',
              '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Code := -1;
  if (Code <> 0) or not FileExists(AdbExe) then
    AddProblem(FmtMessage(CustomMessage('AdbFailed'), [IntToStr(Code)]))
  else
    Log('adb kuruldu: ' + AdbExe);
end;

procedure InstallDriver;
var
  Code: Integer;
begin
  WizardForm.StatusLabel.Caption := CustomMessage('StatusDriver');
  { DisplayTube.exe --install-driver: sertifika, surucu paketi ve sanal ekran cihazi (zaten kuruluysa dokunmaz) }
  if not Exec(ExpandConstant('{app}\DisplayTube.exe'), '--install-driver "' + ExpandConstant('{app}\driver') + '"',
              ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code) then
    Code := -1;
  if Code <> 0 then
    AddProblem(FmtMessage(CustomMessage('DriverFailed'), [IntToStr(Code)]))
  else
    Log('Sanal ekran surucusu kuruldu');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Lang: String;
begin
  if CurStep = ssPostInstall then
  begin
    if ActiveLanguage = 'turkish' then Lang := 'tr' else Lang := 'en';
    SaveStringToFile(ExpandConstant('{app}\language.txt'), Lang, False);

    if AdbDownloaded then
      InstallAdb;
    InstallDriver;

    if Problems <> '' then
      SuppressibleMsgBox(CustomMessage('ProblemsTitle') + #13#10 + Problems + #13#10#13#10 +
                         FmtMessage(CustomMessage('ProblemsLogs'), [ExpandConstant('{log}'),
                                    ExpandConstant('{userappdata}\DisplayTube\log.txt')]),
                         mbError, MB_OK, IDOK);
  end;
end;
