; Inno Setup script for Oberton (formerly Local Dictation).
; Build: scripts\build-installer.ps1 (locally) or the Release GitHub Action (on a v* tag).
; Installs per-user (no admin prompt) to %LOCALAPPDATA%\LocalDictation\app. Runtimes, models and settings live
; next to it in %LOCALAPPDATA%\LocalDictation and are downloaded by the app on first launch, so updates are small
; and keep everything the user has set up. The folder, exe and AppId keep their pre-rename names
; so that updating from Local Dictation 1.x replaces it in place.

#define MyAppName "Oberton"
#define MyAppExe "LocalDictation.exe"
#ifndef MyAppVersion
  #define MyAppVersion "1.2.1"
#endif
#ifndef SourceDir
  #define SourceDir "..\publish"
#endif

[Setup]
AppId={{8E5F1C2A-6B7D-4C3E-9A1F-2D4B6C8E0F13}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=silent-diffusion
AppPublisherURL=https://github.com/silent-diffusion/dictation
AppSupportURL=https://github.com/silent-diffusion/dictation/issues
AppUpdatesURL=https://github.com/silent-diffusion/dictation/releases
VersionInfoVersion={#MyAppVersion}
DefaultDirName={localappdata}\LocalDictation\app
DisableDirPage=yes
DisableProgramGroupPage=yes
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Oberton-Setup-{#MyAppVersion}
SetupIconFile=..\src\Dictation.App\Assets\app.ico
UninstallDisplayIcon={app}\{#MyAppExe}
UninstallDisplayName={#MyAppName}
LicenseFile=..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
CloseApplications=force
RestartApplications=no
UsedUserAreasWarning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"

[InstallDelete]
; Remove files from the previous version so nothing stale is left behind (settings/models live elsewhere).
Type: filesandordirs; Name: "{app}\*"
; Shortcuts from before the rename to Oberton.
Type: files; Name: "{autoprograms}\Local Dictation.lnk"
Type: files; Name: "{autodesktop}\Local Dictation.lnk"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "__pycache__\*,*.pdb"

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Run]
; Interactive install: offer to launch. Silent install (in-app update): always relaunch.
Filename: "{app}\{#MyAppExe}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#MyAppExe}"; Flags: nowait; Check: WizardSilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /T /IM {#MyAppExe}"; Flags: runhidden; RunOnceId: "StopApp"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'LocalDictation');
  if CurUninstallStep = usPostUninstall then
    if SuppressibleMsgBox('Also delete the downloaded AI models, runtimes and your settings?' + #13#10 + #13#10 +
         'They take several GB in ' + ExpandConstant('{localappdata}\LocalDictation') + '.' + #13#10 +
         'Choose No if you plan to reinstall.', mbConfirmation, MB_YESNO, IDNO) = IDYES then
      DelTree(ExpandConstant('{localappdata}\LocalDictation'), True, True, True);
end;
