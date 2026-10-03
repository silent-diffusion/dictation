# Install another local language model (needs internet for the download only).
# Usage: powershell -ExecutionPolicy Bypass -File scripts\pull-model.ps1 qwen3:4b-instruct-2507-q4_K_M
param([Parameter(Mandatory)][string]$Model)
$appHome = if ($env:DICTATION_ROOT) { $env:DICTATION_ROOT } else { "$env:LOCALAPPDATA\LocalDictation" }
$env:OLLAMA_MODELS = "$appHome\models\ollama"
$env:OLLAMA_HOST = "127.0.0.1:11435"
$ollama = "$appHome\runtime\ollama\ollama.exe"
if (-not (Test-Path $ollama)) { throw "Ollama not found at $ollama - start Local Dictation once to finish its setup." }
$running = $false
try { Invoke-RestMethod "http://127.0.0.1:11435/api/version" | Out-Null; $running = $true } catch {}
$p = $null
if (-not $running) { $p = Start-Process $ollama -ArgumentList "serve" -WindowStyle Hidden -PassThru; Start-Sleep 4 }
try { & $ollama pull $Model } finally { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
