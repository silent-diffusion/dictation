param([string]$Configuration = "Release")
. "$PSScriptRoot\env.ps1"
dotnet build "$root\LocalDictation.slnx" -c $Configuration --nologo
