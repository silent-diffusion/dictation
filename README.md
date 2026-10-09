# Oberton

A fully local, AI-assisted dictation app for Windows. (Formerly *Local Dictation*.)

The name is German for *overtone*: the AI adds a layer of polish on top of your own voice.

**Press a hotkey → speak → press it again → cleaned-up text appears at your cursor, in any app.**
**Select text → press `Ctrl+Shift+Space` → hear it read aloud by a natural local voice.**

* Speech recognition: Whisper (via faster-whisper), GPU-accelerated on NVIDIA cards, CPU everywhere else.
* Cleanup: a small local language model (default `qwen2.5:3b`) served by Ollama, driven by editable **profiles**.
* Everything runs on your PC: *Keep everything offline* is on by default. Cloud models (Anthropic's Claude, OpenAI and
  compatible services) are optional, per profile, with your own API key. No accounts, analytics or telemetry.

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

The sidebar has five sections: **Active dashboard** (one screen, no scrolling: what's active and loaded, dials for
words dictated and words read aloud today, turnaround, AI edits kept, history and the speech model's unload countdown, and charts of words per day (dictated and read aloud, side by side) and
the apps you dictate into; the top tiles' text grows with the window. Every tile, dial and chart opens its page when
clicked (History, the profiles, Models, Model unloading); the big number on the speech-model dial unloads that model
right away, and the big number on the History dial copies the last dictation (the text that was inserted) and says so. The figures come from daily counts in
`data\usage.json` (dictations, words, seconds spoken, turnaround, AI edits kept, readings and dictations per app name; never
any text, audio or window titles), so they survive History being trimmed, cleared or off), **Speech to text** (profiles), **Read aloud**, **History** and **Settings**. The menu button
in the top-left corner (✕ while the sidebar is open, ☰ while it's hidden; or **Ctrl+B**) slides the sidebar away to give
the page the whole window. **Back** (after the logo, or next to ☰ while the sidebar is hidden; also `Alt+←` or the mouse's
back button) returns to the page you were on before, Settings sections included; it shows on every page but the dashboard.
With the sidebar hidden, ☰ and Back sit in a fixed bar across the top of the window, so pages scroll underneath it
instead of behind floating buttons, and pages with a side menu of their own (Settings, Speech to text) go right up to the
window's edge.

* **Hotkey** (default `Ctrl+Space`, change under *Hotkeys*): start/stop. `Ctrl+Alt+P` cycles profiles.
* **Overlay**: a pill, always on top, never steals focus. Small while you talk (timer, level meter, active profile, and
  **✕ Cancel**, which stays until the text is in: while starting, recording, transcribing and tidying up);
  while you speak, the words recognized so far run above it; it grows to show your transcript while the AI tidies it, then shows a small dimmed "Inserted" receipt. Hover it to see it clearly;
  click it to see the three boxes used everywhere in the app (the receipt, profile pages, History): **Transcription**,
  **AI Edit** (removed words struck through, new ones highlighted) and **Inserted** (the clean text that went in).
  The text in those boxes can be selected with the mouse, and each box has a **Copy** button (it copies what you selected,
  or the whole box; for AI Edit, the AI's own text without the struck-through words).
  If the safety net rejects the AI's edit, the receipt says so. Position (nine spots) and opacity are under *Settings › Appearance*.
  With *preview before inserting*, the preview shows the same three boxes, with **Inserted** (what *Insert* puts in) brought
  forward, larger and more solid, and the other two dimmed.
  Drag the pill (or the Read aloud player) anywhere; it stays there until Oberton restarts or you pick a position. The Read
  aloud player has its own card under *Settings › Appearance* (opacity, and a position of its own or the pill's).
* **Fits the surrounding text**: a sentence or two around the cursor is read (locally, via Windows accessibility) so a word or phrase
  dictated mid-sentence isn't capitalized or given a period, and missing spaces are added. Works in apps that expose their text
  (Word, browsers, most text boxes); turn it off under *Settings › General*. That text is never stored, logged or sent to the AI.
* **Type as you speak**: finished sentences appear in the app about every 5 seconds while you talk (cleaned up piece by piece).
  Each piece is transcribed once; when you press the hotkey again, only the speech after the last piece is transcribed, and
  the AI cleans up all the pieces together in one final pass that replaces them. The
  replacement only happens after Oberton confirms, through Windows accessibility, that the text before the cursor is exactly
  what it typed; otherwise that text is kept and only the rest is added. `Esc` takes the typed text back the same way.
  Turn it off under *Settings › General*; profiles that preview before inserting don't use it.
  With a profile that doesn't use AI (*Raw*), the words go into the app as they are heard, about every second, the same
  words the overlay shows, and are corrected in place (with Backspace) when the recognizer revises its guess. Each new bit
  is pasted; the profile can type it key by key instead (*Type the words in, instead of pasting them*).
  While you dictate, Oberton holds the clipboard and leaves at least 0.7 s between pastes; your own clipboard comes
  back once the dictation is done, so a paste the app reads late can never insert what you had copied before.
* **No phantom text**: very short or silent recordings insert nothing, so Whisper's habit of hearing "Thank you." in silence never reaches your document.
* **Long dictation** is cleaned up a few sentences at a time (small models stay faithful on short passages), and the safety net applies to each piece separately.
* **Read aloud** (`Ctrl+Shift+Space`): reads the selected text in any app with a natural voice that runs on
  your PC. With nothing selected, it offers to read your clipboard. The player has play/pause, back and forward 15 seconds,
  slower/faster (click the speed itself for a menu from 0.25× to 4×), the time left, and the sentence being read with the current word highlighted. Pick the voice and the base
  speed under *Read aloud*; changing the speed in the player is remembered for the next reading. Every voice paces itself
  naturally from 0.5× to 2×; beyond that the audio is time-stretched without changing its pitch. Three text-to-speech models:
  **Kokoro v1.0** (the most natural; 8 voices, about 370 MB, downloaded the first time you use it), **Piper** (light and fast,
  even on slower PCs; 6 English voices, each a separate 60 to 120 MB download) and **Windows voices** (the ones installed
  with Windows; nothing to download, more robotic). Kokoro and Piper both run in Oberton's local voice server on this PC.
  A profile can pick its own model and voice, for reading its dictations back and for the hotkey while it is active.
  Text is read as plain text: Markdown (headings, lists, **bold**, links, tables, code fences) and stray symbols are dropped.
  The ⌄ button shows the whole text, scrolling along as it is read, with its Markdown shown formatted (headings, bullet
  and numbered lists, quotes, code, bold, italic and links) while the voice reads it as plain text. Click any word in that
  view to have the voice jump there, forwards or backwards. The player's opacity is a setting under *Read aloud*.
* **Settings**: grouped into Dictation, Models & AI, Look & feel and App; each group folds away (remembered).
  **Appearance** follows the Windows light/dark setting, or pick Light or Dark, plus a color scheme (Ember, Ocean,
  Forest, Violet, Rose), each with a light and a dark version.
* **Profiles** (*Speech to text*): *Light Cleanup*, *Grammar & Clarity*, *Natural Phrasing*, *Custom*, *Raw* (no AI: the recognizer's words,
  with the seams between live pieces fixed), plus your own. Edit the prompt, pick a model (only models downloaded to this PC are listed, plus cloud models once
  they are set up), pick its models in one *Models* card: a speech-to-text (Whisper) model, the AI model and a Read aloud model and voice (downloaded ones only; a profile with
  its own speech model loads it when you switch to it, and recording starts right away meanwhile), toggle
  *Use AI* (off hides the instructions, model and other AI settings; only *Raw* has it off), *preview before inserting* (shows the edits; hotkey or *Insert* inserts, `Esc` discards, *Use original* inserts raw),
  *read aloud after inserting* (Read aloud reads what went in), *preserve paragraphs*, *remove fillers*.
  *Rewrite the whole dictation* is for prompts that reshape what you say ("turn my thoughts into an email"): the AI gets the
  whole dictation in one go when you stop. With *Type as you speak*, your words are typed as spoken and the rewrite replaces them at the end.
  The **Try it** panel runs a profile on sample text and shows what it changed, so you can tune prompts without dictating.
  It follows the profile's switches: with *preview before inserting* the real preview appears, with *read aloud after
  inserting* the result is read to you.
* **History**: the last 50 dictations (adjustable under *Settings › History*, up to *All of them*), kept in Oberton's data folder so they survive
  updates. Each has its recording (play it, also at 2×), the Transcription, AI Edit and Inserted boxes (each can be copied),
  and the app and window it went into. List them newest first, or grouped by app (each app's group folds away).
* **Models** (*Settings › Models*): every speech, AI and voice model as a list, showing whether it is downloaded, active and
  loaded, with **Download** and **Use this** buttons. Cloud models are marked CLOUD.
* **Model unloading** (*Settings*): unload models immediately after each use (a few seconds after a dictation or reading
  ends; they stay loaded while in use), after 5 minutes to 4 hours unused (default 30 minutes), or never; or
  right now (*Unload everything*, or the speech model, AI model or Read aloud voice alone). Dictating
  never waits for a model: recording starts at once and the speech model catches up when it has loaded.
* **Cloud AI** (*Settings*): API keys (encrypted for your Windows account) and the *Keep everything offline* switch.
* If the AI fails, is unreachable, or returns something implausible (empty, summarised, rambling), your **raw words are inserted instead** - dictation is never lost.

### Other models

```powershell
powershell -ExecutionPolicy Bypass -File scripts\pull-model.ps1 qwen3:4b-instruct-2507-q4_K_M   # any Ollama tag
```
Or download models from **Settings › Models**, and pick the active one there (or per profile).

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
