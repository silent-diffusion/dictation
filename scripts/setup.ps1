<#
  Developer setup: downloads a portable .NET 10 SDK into tools\ (nothing system-wide).
  The speech engine, AI runtime and models are NOT installed here: the app downloads them itself on first launch
  (into %LOCALAPPDATA%\LocalDictation), exactly like an installed copy does.
  Usage: powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
#>
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root  = Split-Path $PSScriptRoot -Parent
$tools = Join-Path $root "tools"
New-Item -ItemType Directory -Force $tools | Out-Null
if (-not (Test-Path "$tools\dotnet\dotnet.exe")) {
    Invoke-WebRequest "https://dot.net/v1/dotnet-install.ps1" -OutFile "$tools\dotnet-install.ps1"
    & "$tools\dotnet-install.ps1" -Channel 10.0 -InstallDir "$tools\dotnet" -NoPath
}
& "$tools\dotnet\dotnet.exe" --version
Write-Host "Done. Build and run with:  powershell -ExecutionPolicy Bypass -File scripts\run.ps1"
