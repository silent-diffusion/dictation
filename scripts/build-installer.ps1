# Builds dist\Oberton-Setup-<version>.exe locally - the same thing the Release GitHub Action does.
# Uses a portable Inno Setup in tools\inno (downloaded on first use).
param([string]$Version = "1.0.0")
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. "$PSScriptRoot\env.ps1"
$iscc = "$root\tools\inno\ISCC.exe"
if (-not (Test-Path $iscc)) {
    $setupExe = "$root\tools\innosetup.exe"
    Invoke-WebRequest "https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/innosetup-7.1.0-x64.exe" -OutFile $setupExe
    $innoArgs = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/PORTABLE=1", "/DIR=`"$root\tools\inno`"")
    Start-Process $setupExe -ArgumentList $innoArgs -Wait
}
$pub = "$root\publish"
if (Test-Path $pub) { Remove-Item $pub -Recurse -Force }
dotnet publish "$root\src\Dictation.App\Dictation.App.csproj" -c Release -r win-x64 --self-contained true -p:Version=$Version -o $pub --nologo -v q
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Copy-Item "$root\inference" "$pub\inference" -Recurse
Get-ChildItem "$pub\inference" -Recurse -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
& $iscc "/DMyAppVersion=$Version" "/DSourceDir=..\publish" "$root\installer\LocalDictation.iss" | Select-Object -Last 3
Write-Host "Installer: $root\dist\Oberton-Setup-$Version.exe"
