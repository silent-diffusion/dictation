# Test brief: Oberton 2.0.0 "Read aloud"

You are testing a new feature of **Oberton**, a local AI dictation app for Windows, on the user's own PC. You start in
an **empty directory**. Everything you need is described here. Work through the steps in order, record what happens,
and finish with the report described at the end. Don't fix code unless asked; your job is to find out what works.

## What Oberton is

- Desktop app, **Windows 10/11 x64, WPF on .NET 10**. Source: https://github.com/silent-diffusion/dictation (public).
- Dictation: hotkey `Ctrl+Space` records, Whisper transcribes, a local LLM (Ollama) cleans up, the text is pasted
  at the cursor. All local.
- Releases are built by GitHub Actions. Installed copies update via *Settings › About & updates*.

## What's new in 2.0.0 (what you are testing)

**Read aloud**: select text in any app, press `Ctrl+Shift+Space`, and it is spoken by **Kokoro v1.0** (an 82M-parameter
TTS model, ONNX, CPU) running in a local Python process.

| Piece | Where |
| --- | --- |
| Voice server (Python, WebSocket, one sentence per request) | `inference/tts_server.py` |
| Python dependency, installed on first use | `inference/requirements-tts.txt` (`kokoro-onnx>=0.4.9,<0.7`) |
| On-demand installer (pip via `uv` + model downloads) | `src/Dictation.Core/Setup/RuntimeInstaller.cs` → `InstallReadAloudAsync` |
| C# client for the server | `src/Dictation.Core/Speech/KokoroSpeech.cs` |
| Sentence splitting | `src/Dictation.Core/Reading/ReadAloudText.cs` |
| Playback (NAudio), pause, ±15 s, speed, time left | `src/Dictation.Core/Reading/ReadAloudSession.cs` |
| Reading the selection (UI Automation, else Ctrl+C with clipboard restore) | `src/Dictation.Core/Insertion/SelectionReader.cs` |
| Player popup | `src/Dictation.App/Views/ReaderWindow.xaml(.cs)` |
| Settings › Read aloud (voice, base speed, download, Try it) | `src/Dictation.App/Views/ReadAloudPage.xaml(.cs)` |
| Hotkey wiring | `src/Dictation.App/App.xaml.cs` → `OnSpeakHotkey` |

**Never tested outside CI.** The app compiles, and 69 unit tests pass on GitHub's Windows runners. Nothing has run on a
real machine yet. The riskiest step is the first-use install of `kokoro-onnx` (and its dependencies `onnxruntime`,
`espeakng-loader`, `phonemizer`) into the app's private Python. That step has never run anywhere.

## Paths on the user's machine

`%LOCALAPPDATA%\LocalDictation` is the data root. The folder keeps its pre-rename name on purpose.

| What | Path |
| --- | --- |
| Installed program | `%LOCALAPPDATA%\LocalDictation\app\` (exe: `LocalDictation.exe`) |
| Python scripts shipped with the app | `%LOCALAPPDATA%\LocalDictation\app\inference\` |
| Private Python | `%LOCALAPPDATA%\LocalDictation\runtime\py\python.exe` |
| `uv` (installer tool) | `%LOCALAPPDATA%\LocalDictation\runtime\uv\uv.exe` |
| Kokoro model + voices | `%LOCALAPPDATA%\LocalDictation\models\kokoro\kokoro-v1.0.onnx` (~325 MB), `voices-v1.0.bin` (~28 MB) |
| Settings | `%LOCALAPPDATA%\LocalDictation\data\settings.json` |
| **Log** (check after every step) | `%LOCALAPPDATA%\LocalDictation\data\logs\dictation.log` |

Read aloud counts as installed when both model files exist and
`runtime\py\Lib\site-packages\kokoro_onnx\` exists.

## Step 0: Set up the working folder and check the machine

Run in PowerShell in the empty directory:

```powershell
git clone --depth 1 https://github.com/silent-diffusion/dictation.git src-dictation   # source, for reference only
Invoke-WebRequest https://github.com/silent-diffusion/dictation/releases/download/v2.0.0/Oberton-Setup-2.0.0.exe -OutFile Oberton-Setup-2.0.0.exe
$root = "$env:LOCALAPPDATA\LocalDictation"
Test-Path "$root\runtime\py\python.exe"          # is Oberton (or Local Dictation 1.x) already set up?
(Get-Item "$root\app\LocalDictation.exe" -ErrorAction SilentlyContinue).VersionInfo.ProductVersion
```

- **Already installed and older than 2.0.0:** ask the user to update in the app (*Settings › About & updates › Check
  for updates*), or run `.\Oberton-Setup-2.0.0.exe` (it updates in place and keeps settings and models).
- **Not installed:** run the installer. First launch downloads the speech engine and models (3–5.5 GB, several
  minutes) before anything else works. Let it finish.
- Record the Windows version, CPU, RAM, and whether there's an NVIDIA GPU (`nvidia-smi -L`).

## Step 1: Install the voice exactly as the app does (automated, most important)

Do this **before** testing in the UI. It reproduces the app's install step and gives clean error output if it fails.

```powershell
$root = "$env:LOCALAPPDATA\LocalDictation"
$py   = "$root\runtime\py\python.exe"
$uv   = "$root\runtime\uv\uv.exe"
$env:UV_CACHE_DIR = "$root\runtime\uv-cache"; $env:UV_LINK_MODE = "copy"; $env:UV_PYTHON_DOWNLOADS = "never"
& $uv pip install --python $py --system --break-system-packages -r "$root\app\inference\requirements-tts.txt"
& $py -c "import kokoro_onnx, onnxruntime, numpy; print('kokoro-onnx ok', onnxruntime.__version__, numpy.__version__)"
& $py -m pip list 2>$null | Select-String "kokoro|onnx|espeak|phonemizer|numpy|websockets"
```

Then download the model files to where the app expects them:

```powershell
$k = "$root\models\kokoro"; New-Item -ItemType Directory -Force $k | Out-Null
$base = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
if (!(Test-Path "$k\kokoro-v1.0.onnx")) { Invoke-WebRequest "$base/kokoro-v1.0.onnx" -OutFile "$k\kokoro-v1.0.onnx" }
if (!(Test-Path "$k\voices-v1.0.bin"))  { Invoke-WebRequest "$base/voices-v1.0.bin"  -OutFile "$k\voices-v1.0.bin" }
Get-ChildItem $k | Select-Object Name, Length
```

Report:
- Did `uv pip install` succeed?
- Which versions resolved?
- Did the import line print `kokoro-onnx ok`?
- Any conflict with the speech engine's pinned `numpy==2.5.3`?

If you can't get it to work, still finish Step 1b's checks that don't need it, and report the full error.

> If you'd rather test the in-app install path instead, skip Step 1, then trigger it from the app in Step 3 or 4
> (the app runs the same `uv pip install` and downloads). You can't do both on one machine without first deleting
> `runtime\py\Lib\site-packages\kokoro_onnx*` and `models\kokoro\`. Prefer the in-app path if the user agrees, because
> it tests more code. In that case use Step 1 only to diagnose a failure.

### Step 1b: Test the voice server on its own (automated)

Start the server on a spare port, so it doesn't clash with the app's 8766:

```powershell
$srv = Start-Process $py -ArgumentList "-u","$root\app\inference\tts_server.py","--model","$root\models\kokoro\kokoro-v1.0.onnx","--voices","$root\models\kokoro\voices-v1.0.bin","--port","8799" -PassThru -RedirectStandardOutput tts.out.txt -RedirectStandardError tts.err.txt -NoNewWindow
Start-Sleep 20; Get-Content tts.out.txt   # expect a line starting with READY port=8799 (ERROR ... means the model failed to load)
```

Save this as `tts_probe.py` and run it with `& $py tts_probe.py`. It talks to the server exactly like the app does:

```python
import asyncio, json, time, wave
import numpy as np
from websockets.asyncio.client import connect

CASES = [
    ("Hello! This is how Oberton sounds when it reads to you.", "af_heart", 1.0),
    ("The same sentence, read a little faster this time.", "af_heart", 1.5),
    ("And slower, for careful listening.", "af_heart", 0.6),
    ("A British voice, reading the news.", "bm_george", 1.0),
    ("Numbers like 3.5 million, dates like 12 March 2026, and emails like a@b.com.", "af_bella", 1.0),
    ("", "af_heart", 1.0),                       # empty text: must not crash the server
    ("Unknown voice falls back.", "zz_nobody", 1.0),
]

async def main():
    async with connect("ws://127.0.0.1:8799/", max_size=2**24) as ws:
        print("greeting:", (await ws.recv())[:120])
        for i, (text, voice, speed) in enumerate(CASES):
            t = time.time()
            await ws.send(json.dumps({"type": "speak", "id": i, "text": text, "voice": voice, "speed": speed}))
            meta = json.loads(await ws.recv())
            if meta["type"] == "error":
                print(i, "ERROR", meta["message"]); continue
            pcm = np.frombuffer(await ws.recv(), dtype="<f4")
            secs = pcm.size / meta["rate"]
            print(f"{i}: {voice} x{speed}: {secs:.2f}s audio in {time.time()-t:.2f}s, peak {np.abs(pcm).max():.2f}")
            with wave.open(f"probe_{i}.wav", "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(meta["rate"])
                w.writeframes((np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes())

asyncio.run(main())
```

Expected results:
- Each case prints a duration. Faster speed means shorter audio, and slower means longer.
- Synthesis should run faster than real time on a modern CPU.
- The `.wav` files sound right when played. Ask the user to listen to a couple, or play them with
  `(New-Object Media.SoundPlayer "probe_0.wav").PlaySync()`.
- Empty text and an unknown voice give either a short or empty result or an `error` message. They must **not** kill the
  server.

Stop the server afterwards with `Stop-Process $srv.Id`.

## Step 2: Before testing the UI

- Make sure Oberton 2.0.0 is running (tray icon: a red dot on a dark square).
- Open `dictation.log` and note its length, so you can show only the new lines later.
- Steps 3–6 need someone to press keys and watch the screen. If you have desktop control (computer use), do them
  yourself. Otherwise give the user the steps one at a time and record what they report.

## Step 3: Settings › Read aloud

1. Open Oberton (tray icon), then **Settings** (bottom of the sidebar), then **Read aloud** (under *Speech & AI*).
2. Expected: "Voice installed" if Step 1 ran; otherwise "Voice not installed yet" with a **Download voice** button.
3. If it's not installed, click **Download voice**. Watch the progress (installing the voice engine, then the model,
   then the voices) and record how long it takes and any error.
4. Click **Try it**. A popup should appear at the overlay position (bottom center by default) and read a sample
   sentence. Record the time from click to first sound.
5. Change the **Voice** (e.g. George, British) and the **Base speed** (e.g. 1.30×), click **Try it** again, and check
   both changes are heard.
6. Check that `data\settings.json` now contains the new `TtsVoice` and `TtsBaseSpeed`.

## Step 4: Hotkey with a selection, in different apps

For each app, select a paragraph of 3–6 sentences and press **Ctrl+Shift+Space**. Do Notepad, Word (if installed),
Chrome or Edge on a normal web page, and one Electron app (VS Code or Slack) if available.

| Check | Expected |
| --- | --- |
| Reading starts | Within ~1–3 s, with the player popup visible |
| Text matches | It reads the selection, not the whole document or line |
| Clipboard untouched | Copy something distinctive first; after reading, pasting still gives it |
| Focus | The app you were in keeps focus (you can keep typing there) |
| Press Ctrl+Shift+Space again | Stops reading and closes the popup |

Note which apps used UI Automation and which needed the Ctrl+C fallback. The log line "Selection not readable via UI
Automation" means the fallback was used.

## Step 5: Nothing selected (clipboard prompt)

1. Copy a few sentences to the clipboard. Click somewhere with **no** selection (e.g. an empty Notepad) and press
   `Ctrl+Shift+Space`.
   Expected: the popup asks "Nothing is selected. Read your clipboard?" with a preview, a word count and estimated
   minutes, plus **Read clipboard** and **Cancel** buttons. **Read clipboard** reads it; **Cancel** closes the popup.
2. Clear the clipboard (`Set-Clipboard -Value $null`), deselect, and press the hotkey.
   Expected: a short overlay message asking you to select text first.
3. Known risk: in VS Code, Ctrl+C with no selection copies the whole line. Check whether that gets read instead of
   showing the prompt.

## Step 6: Player controls

Use a long text (~2–3 minutes, e.g. a Wikipedia article section) so there's room to test:

| Control | Expected |
| --- | --- |
| Pause / play | Stops and resumes at the same word; the status reads "Paused" |
| Back 15 s / Forward 15 s | Jumps roughly 15 s; the highlighted text moves with it; forward near the end finishes |
| − / + speed | Steps of 0.1× from 0.5× to 2.0×; the pace changes within about a second, the pitch stays natural, buttons disable at the limits |
| Countdown | "m:ss" time left, counting down; it settles to an accurate value after a few sentences and adjusts when speed changes |
| Progress bar | Fills left to right over the whole text |
| Highlight | Current sentence on at most 2 lines; spoken words white, the current word orange, the rest dimmed; long sentences show a moving "…" window |
| End | Shows "Done"; the popup closes ~4 s later unless the mouse is over it; Play on "Done" reads again from the start |
| ✕ | Stops immediately |
| Speed reset | A new reading starts at the base speed from settings, not the last − / + value |

Also try the text kinds below.

| Text | What to check |
| --- | --- |
| A bulleted list | Each line read as its own piece |
| A very long sentence (no full stop for 400+ characters) | Splits at commas, no long silence or cut-off |
| Text with URLs, numbers, symbols | No crash; note anything mispronounced |
| Non-English text | Probably read with English phonetics. That's expected; just note it |

## Step 7: Quick regression check of dictation (1.1–1.2 features)

| Check | Expected |
| --- | --- |
| Short dictation (`Ctrl+Space`, a sentence, `Ctrl+Space`) | Inserted correctly |
| 20–30 s dictation with *Type as you speak* on | Sentences appear while talking; one final replacement on stop |
| Short silent tap | Nothing inserted (no phantom "Thank you.") |
| `Ctrl+Space` while reading aloud | Neither feature breaks the other |

## Report back in this format

```
Machine: Windows <ver>, CPU <model>, RAM <GB>, NVIDIA GPU <yes/no + model>
Oberton version tested: <from Settings › About & updates>
Step 1 install: PASS/FAIL. Resolved versions: kokoro-onnx <x>, onnxruntime <x>, numpy <x>. Errors: <verbatim>
Step 1b server: PASS/FAIL. Per-case durations / timings / errors: <paste probe output>
Step 3 settings: PASS/FAIL. Download time <x>, first sound after Try it <x s>. Notes
Step 4 apps: <app: UIA or Ctrl+C fallback, PASS/FAIL, notes> for each app
Step 5 clipboard: PASS/FAIL. Notes (incl. VS Code)
Step 6 controls: <control: PASS/FAIL + notes> for each row
Step 7 regression: PASS/FAIL. Notes
Log excerpt: <new lines from dictation.log since Step 2 that mention tts, Read aloud, error or warn>
Bugs found: <numbered list: steps to reproduce, expected, actual, suspected file from the table above>
```

Paste the report back into the conversation with the developer's assistant, along with any error messages verbatim.
