; ARGB Controller — Windows kurulum paketi (Inno Setup 6.x)
;
; Doğrudan derlemeyin; üretim için scripts\build-windows-installer.ps1 kullanın (sürüm, kaynak klasörü ve VC++ DLL'lerini hazırlar).
; Elle derleme: ISCC /DAppVersion=0.2.0 /DAppVersionInfo=0.2.0.1 /DSourceDir=C:\...\dist\stage installer\ARGBController.iss
;
; Tasarım kararları:
;  * Kullanıcı bazlı kurulum (yönetici gerekmez): %LOCALAPPDATA%\Programs\ARGB Controller. Kurulum sihirbazı "tüm kullanıcılar" için
;    yükseltilmiş kurulum seçeneği sunar (PrivilegesRequiredOverridesAllowed=dialog).
;  * AppId SABİTTİR: aynı AppId ile çalıştırılan yeni sürüm, eskisinin üzerine (yerinde) kurulur.
;  * Kullanıcı ayarları ve eşleştirme token'ları kurulum klasörünün DIŞINDADIR (%APPDATA%\ARGB LED Control\ARGB Controller\);
;    kurulum/güncelleme/yeniden kurulum bu klasöre dokunmaz. Kaldırırken varsayılan olarak da silinmez (sorulur; sessiz kaldırmada korunur).
;  * Gerekli Microsoft VC++ çalışma zamanı DLL'leri (msvcp140, vcruntime140, vcruntime140_1) uygulama klasörüne konur (uygulama-yerel dağıtım).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppVersionInfo
  #define AppVersionInfo "0.0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\stage"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

#define AppName "ARGB Controller"
#define AppExeName "ARGBController.exe"
#define AppPublisher "ARGB LED Control"
#define AppURL "https://github.com/ufukkivanc/ARGB_LED_CONTROL"
; Windows'ta ayar klasörü: %APPDATA%\<CompanyName>\<ProductName> (windows\runner\Runner.rc ile AYNI olmalı)
#define SettingsCompany "ARGB LED Control"
#define SettingsProduct "ARGB Controller"
#define LegacyCompany "com.argbled"
#define LegacyProduct "argb_controller"

[Setup]
; Bu GUID'i ASLA değiştirmeyin (güncellemelerin aynı uygulamayı tanıması için).
AppId={{C02320E8-F7E1-4A83-8E1D-09DE273120A7}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion={#AppVersionInfo}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
DefaultDirName={autopf}\{#AppName}
UsePreviousAppDir=yes
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=ARGBController-Setup-{#AppVersion}
SetupIconFile=..\argb_controller_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
turkish.DesktopIcon=Masaüstüne kısayol oluştur
turkish.LaunchApp={#AppName} uygulamasını başlat
turkish.AskRemoveData=Kullanıcı ayarları ve cihaz eşleştirmeleri de silinsin mi?%n%nHayır'ı seçerseniz ayarlarınız ve eşleştirmeleriniz korunur (yeniden kurulumda geri gelir).
english.DesktopIcon=Create a desktop shortcut
english.LaunchApp=Launch {#AppName}
english.AskRemoveData=Also delete user settings and device pairings?%n%nChoose No to keep them (they will be available again after reinstalling).

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[Code]
function SettingsDir(): String;
begin
  Result := ExpandConstant('{userappdata}\{#SettingsCompany}\{#SettingsProduct}');
end;

function LegacySettingsDir(): String;
begin
  Result := ExpandConstant('{userappdata}\{#LegacyCompany}\{#LegacyProduct}');
end;

// Geliştirme sürümleri ayarlarını eski klasöre yazıyordu. Yeni klasör yoksa BİR KEZ kopyalanır (silinmez).
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if (CurStep = ssPostInstall) and DirExists(LegacySettingsDir()) and (not DirExists(SettingsDir())) then
  begin
    if ForceDirectories(SettingsDir()) then
      Exec(ExpandConstant('{cmd}'),
           '/C xcopy "' + LegacySettingsDir() + '\*" "' + SettingsDir() + '\" /E /I /Y /Q',
           '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

// Kaldırma: kullanıcı verisi varsayılan olarak KORUNUR. Etkileşimli kaldırmada sorulur; sessiz kaldırmada asla silinmez.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and (not UninstallSilent()) and DirExists(SettingsDir()) then
  begin
    if MsgBox(ExpandConstant('{cm:AskRemoveData}'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(SettingsDir(), True, True, True);
  end;
end;
