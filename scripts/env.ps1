# Dot-source this to get the project-local .NET SDK on PATH (nothing system-wide is touched).
$root = Split-Path $PSScriptRoot -Parent
$env:DOTNET_ROOT = "$root\tools\dotnet"
$env:PATH = "$root\tools\dotnet;$env:PATH"
$env:DOTNET_CLI_HOME = "$root\tools\dotnet-home"
$env:NUGET_PACKAGES = "$root\tools\nuget"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"
