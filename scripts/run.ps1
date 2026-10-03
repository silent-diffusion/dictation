param([string]$Configuration = "Release", [switch]$Minimized)
. "$PSScriptRoot\env.ps1"
dotnet build "$root\src\Dictation.App\Dictation.App.csproj" -c $Configuration --nologo -v q
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$exe = Get-ChildItem "$root\src\Dictation.App\bin\$Configuration" -Recurse -Filter LocalDictation.exe | Select-Object -First 1
$a = @(); if ($Minimized) { $a += "--minimized" }
& $exe.FullName @a
