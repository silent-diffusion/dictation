# Oberton

A fully local, AI-assisted dictation app for Windows. (Formerly *Local Dictation*.)

The name is German for *overtone*: the AI adds a layer of polish on top of your own voice.

**Press a hotkey → speak → press it again → cleaned-up text appears at your cursor, in any app.**

* Speech recognition: Whisper (via faster-whisper), GPU-accelerated on NVIDIA cards, CPU everywhere else.
* Cleanup: a small local language model (default `qwen2.5:3b`) served by Ollama, driven by editable **profiles**.
* Everything runs on your PC. No cloud APIs, accounts, analytics or telemetry.

---

## Install

1. Download **`Oberton-Setup-x.y.z.exe`** from the [latest release](https://github.com/silent-diffusion/dictation/releases/latest).
2. Run it. Windows may show *"Windows protected your PC"* because the installer isn't code-signed yet - click **More info → Run anyway**.
   No administrator rights are needed; it installs just for your user account.
3. On first launch the app downloads its speech engine, AI runtime and models (one time, needs internet):

| | NVIDIA GPU | No NVIDIA GPU |
|---|---|---|
| Download | ~5.5 GB | ~3 GB |
| Speech model | `large-v3-turbo` | `small.en` |
| Typical wait after you stop talking (20 s of speech) | **~1-2.5 s** | **~8 s** (measured on a Ryzen 7 5800HS) |

Then click into any text field, press **Ctrl+Space**, talk, and press **Ctrl+Space** again.
The app lives in the system tray; closing the window keeps it running.

**Requirements:** Windows 10 (1809+) or 11, 64-bit, ~8 GB free disk. An NVIDIA GPU with 6 GB+ is recommended but optional.

### Updating

*Settings → About & Updates → Check for updates* (or the tray menu). If there's a newer release it downloads the installer
and updates in place; your settings, profiles and downloaded models are kept. You can also turn on *Check for updates when Oberton starts*.

### Uninstalling

*Windows Settings → Apps → Oberton → Uninstall*. You'll be asked whether to also delete the downloaded models and settings.

### Where things are

| Path | What |
|---|---|
| `%LOCALAPPDATA%\LocalDictation\app` | the program (replaced on update) |
| `%LOCALAPPDATA%\LocalDictation\runtime` | private Python 3.12 + speech engine, portable Ollama |
| `%LOCALAPPDATA%\LocalDictation\models` | Whisper and language models |
| `%LOCALAPPDATA%\LocalDictation\data` | `settings.json`, `profiles.json`, `logs\` |

The folder keeps its pre-rename name so updates from Local Dictation 1.x keep your models and settings.

---

## Using it

* **Hotkey** (default `Ctrl+Space`, change under *Hotkeys*): start/stop. `Ctrl+Alt+P` cycles profiles.
* **Overlay**: a pill, always on top, never steals focus. Small while you talk (timer, level meter, active profile, `✕` cancels);
  it grows to show your transcript while the AI tidies it, then shows a small dimmed "Inserted" receipt. Hover it to see it clearly;
  click it to compare what you said with the AI's edit side by side (removed words struck through).
  If the safety net rejects the AI's edit, the receipt says so. Position (nine spots) and opacity are under *Settings › Appearance*.
* **Fits the surrounding text**: a sentence or two around the cursor is read (locally, via Windows accessibility) so a word or phrase
  dictated mid-sentence isn't capitalized or given a period, and missing spaces are added. Works in apps that expose their text
  (Word, browsers, most text boxes); turn it off under *Settings › General*. That text is never stored, logged or sent to the AI.
* **No phantom text**: very short or silent recordings insert nothing, so Whisper's habit of hearing "Thank you." in silence never reaches your document.
* **Long dictation** is cleaned up a few sentences at a time (small models stay faithful on short passages), and the safety net applies to each piece separately.
* **Settings** (bottom of the sidebar): grouped into Dictation, Speech & AI, Look & feel and App. **Appearance** follows the
  Windows light/dark setting, or pick Light or Dark.
* **Profiles** (sidebar): *Light Cleanup*, *Grammar & Clarity*, *Natural Phrasing*, *Custom*, plus your own. Edit the prompt, pick a model, toggle
  *auto-process*, *preview before inserting* (shows the edits; hotkey or *Insert* inserts, `Esc` discards, *Use original* inserts raw), *preserve paragraphs*, *remove fillers*.
  The **Try it** panel runs a profile on sample text and shows what it changed, so you can tune prompts without dictating.
* **History**: the last 25 dictations, raw next to processed, in memory only. "Insert raw into the last app" is the manual undo-to-raw.
* If the AI fails, is unreachable, or returns something implausible (empty, summarised, rambling), your **raw words are inserted instead** - dictation is never lost.

### Other models

```powershell
powershell -ExecutionPolicy Bypass -File scripts\pull-model.ps1 qwen3:4b-instruct-2507-q4_K_M   # any Ollama tag
```
Then pick it under **AI Models** (or per profile). Whisper models (`large-v3-turbo`, `distil-large-v3`, `small.en`, `base.en`, …) are chosen under **Speech Recognition**.

---

## Privacy

* Speech recognition and the language model run locally. Whisper runs with `HF_HUB_OFFLINE=1`; the Ollama endpoint must be loopback (other values are rejected) and Ollama's cloud features are disabled.
* Audio exists only in memory during a dictation and is discarded. Logs record timings and sizes, never what you said.
* Network access happens only for: the first-run download, and checking for updates (when you click it, or at startup if you enable that).
  The update check is a plain request for this repository's public release list.

---

## Architecture

```
┌──────────────────────── Dictation.App (WPF, UI only) ────────────────────────┐
│ MainWindow + pages · OverlayWindow (WS_EX_NOACTIVATE) · TrayIcon · HotkeyManager │
│ SetupWindow (first run) · AboutPage (updates)                                  │
└───────────────┬───────────────────────────────────────────────────────────────┘
                │ events / commands
┌───────────────▼──────────────── Dictation.Core (no UI) ───────────────────────┐
│ DictationController  (state machine: Idle→Recording→Transcribing→Processing→  │
│                       [Confirming]→Inserting)                                  │
│   IAudioCapture ─ MicCapture (NAudio) / FileAudioCapture (tests)               │
│   ISpeechRecognizer ─ SidecarSpeechRecognizer ──WebSocket 127.0.0.1──┐         │
│   ITextProcessor ─ OllamaTextProcessor ──HTTP 127.0.0.1──┐           │         │
│   TextInserter ─ ITextInsertionStrategy: ClipboardPaste | UnicodeTyping        │
│   RuntimeInstaller (first-run downloads) · UpdateService (GitHub Releases)     │
│   SettingsService · ProfileService · Log · ChildProcessJob                     │
└───────────────────────────────────────────────────────┼───────────┼───────────┘
                                                         │           │
                                         runtime\ollama (Ollama)   inference\asr_server.py
                                                                   (faster-whisper, CUDA or CPU)
```

* **Replaceable engines.** `ISpeechRecognizer` and `ITextProcessor` are the only things the controller knows. The Python server has a small
  `ENGINES` registry - add a class there (e.g. NVIDIA Parakeet) and select it in settings. Any Ollama model works for cleanup.
* **Small installer, big runtime.** The setup `.exe` (~50 MB) contains only the self-contained .NET app and the Python sidecar script.
  `RuntimeInstaller` downloads pinned versions of standalone CPython, the speech packages (`inference\requirements*.txt`), Ollama and the
  models on first launch. Every step is resumable, and the Python runtime is a plain relocatable folder (no virtualenv, no links).
* **Updates** come from GitHub Releases: `UpdateService` compares the latest release tag with the app version, downloads the installer and runs it
  silently; the installer replaces only `app\` and restarts the app.
* **Child processes die with the app** (Windows Job Object), even on a crash.
* **Insertion** remembers the foreground window at hotkey time, waits for the hotkey's modifier keys to be released, restores the target if needed,
  then pastes (Ctrl+V) - atomic, so it is reliable in Chromium/Electron apps, which drop or repeat characters when flooded with injected keystrokes.
  The clipboard is snapshotted and restored, and the temporary text is excluded from clipboard history/cloud sync. Paced Unicode typing is the
  fallback (or a per-app choice via `AppOverrides` in `settings.json`).

### Project layout

```
inference/                  Whisper sidecar (WebSocket, loopback only) + pinned requirements
src/Dictation.Core/         Audio, Speech, Text, Insertion, Session, Settings, Setup, Infrastructure
src/Dictation.App/          WPF app (Views/, Services/)
tests/Dictation.Tests/      xUnit tests
installer/                  Inno Setup script
scripts/                    developer scripts (setup, run, build, build-installer, pull-model)
.github/workflows/          CI (build + test) and Release (tag → installer → GitHub release)
```

---

## Development

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1   # portable .NET 10 SDK into tools\ (nothing system-wide)
powershell -ExecutionPolicy Bypass -File scripts\run.ps1     # build + run; first launch runs the same first-run setup as an install
. scripts\env.ps1; dotnet test tests\Dictation.Tests -c Release
powershell -ExecutionPolicy Bypass -File scripts\build-installer.ps1 -Version 1.2.3   # local installer in dist\
```

A development copy shares `%LOCALAPPDATA%\LocalDictation` (runtimes, models, settings) with an installed copy. Set `DICTATION_ROOT` to use a different folder.
Test hooks: `DICTATION_FAKE_AUDIO=<16 kHz mono wav>` speaks a file instead of the microphone; `DICTATION_FORCE_CPU=1` simulates a PC without an NVIDIA GPU.

### Releasing a new version

```powershell
git tag v1.2.3
git push origin v1.2.3
```
The *Release* workflow tests, builds `Oberton-Setup-1.2.3.exe` and publishes the GitHub release. Installed copies see it under *Check for updates*.

No local clone? On GitHub open *Actions › Release › Run workflow*, pick `main`, type `1.2.3` and run it: it creates the `v1.2.3` tag for you.

---

## GPU memory guide (6 GB cards)

Whisper `large-v3-turbo` uses ~1.2 GB; the 3B language model needs ~2.3 GB plus a safety margin; Windows and other apps (browsers, chat apps)
also use VRAM. If the model doesn't fit, Ollama silently puts part of it on the CPU and cleanup slows from ~0.4 s to 2-3 s.
The status line at the bottom-left of the window shows the split (e.g. `qwen2.5:3b · GPU` or `· 5% GPU (slower…)`).
If you see a low GPU percentage: close GPU-hungry apps, choose a smaller model, or a smaller Whisper (`small.en`).
With more VRAM, `qwen3:4b-instruct-2507-q4_K_M` gives noticeably better edits.

## Troubleshooting

| Symptom | Fix |
|---|---|
| First-run setup fails | check your internet connection and click *Continue setup* - it resumes where it stopped |
| Hotkey does nothing / overlay says "already used" | another app owns the shortcut → *Hotkeys* page, pick another |
| Text isn't inserted into an elevated (admin) app | Windows blocks input between privilege levels → run Oberton as administrator too |
| Cleanup is slow | see the GPU memory guide above |
| Mic meter flat | *Audio* page → pick another mic; Windows *Privacy & security → Microphone* must allow desktop apps |
| Anything else | `%LOCALAPPDATA%\LocalDictation\data\logs\dictation.log` (*Advanced → Open logs*) |

## Known limitations

* **Parakeet is not implemented yet.** The engine slot exists, but NVIDIA NeMo/Parakeet has no first-class Windows runtime today (ONNX builds are the likely route).
* Live text is a re-decode of the recent audio (≈ every 0.6 s), so the last words can change as you keep talking. Only the final transcript is cleaned by the language model.
* Very long dictations (>10 min by default) are cut off; the cleanup step is chunked at sentence boundaries.
* Small (3B) language models sometimes keep an "um", or collapse a self-correction ("three, no wait, four" → "four").
* A clipboard manager may briefly see the dictated text while it is pasted.
* Only the primary monitor is used for the overlay position.
* English-first: other languages work in Whisper (set *Language*), but the built-in prompts and examples are English.
* The installer isn't code-signed, so Windows SmartScreen warns on first run.

## Roadmap

1. Parakeet-TDT engine (ONNX) behind `ISpeechRecognizer`.
2. Streaming partials with stable-prefix commit (fewer word flips) and silence-based auto-stop.
3. One-key undo: replace the inserted text with the raw transcript in the target app.
4. Per-application profiles and a UI for `AppOverrides`.
5. Auto-pick models by free VRAM; model download UI inside the app.
6. Voice commands ("new paragraph", "scratch that"), custom vocabulary/replacement lists.
7. Code signing; multi-monitor overlay placement.

## License

[MIT](LICENSE) © silent-diffusion
