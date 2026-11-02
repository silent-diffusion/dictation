# Oberton for Mac and iPhone

A native SwiftUI port of Oberton: one codebase for macOS 26+ and iOS 26+. The same profiles, prompts, examples and
safety net as the Windows app, with one addition: **Apple Intelligence** (Apple's on-device model) as an AI choice, and the
default where it is available. Nothing to install, nothing leaves the device.

```
MIC ──→ SPEECH ──→ AI ──→ INSERT
        Apple Speech  Apple Intelligence · Ollama · Claude · OpenAI   at the cursor (Mac) / clipboard (iPhone)
        (on-device)   (profiles)                                       ┆
                                                                       └┄┄ READ ALOUD  system voices
```

## Build and run

Open `Oberton.xcodeproj` in Xcode 27 and run the **Oberton** scheme on *My Mac* or an iPhone. From the command line:

```bash
xcodebuild -project Oberton.xcodeproj -scheme Oberton -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build
open build/Build/Products/Debug/Oberton.app
```

The core logic has its own tests, ported from `tests/Dictation.Tests/TextProcessingTests.cs`:

```bash
cd ObertonCore && swift test
```

On first launch the Mac asks for the **microphone** and for **Accessibility** (to paste at the cursor). Press `Ctrl+D` in any
app, speak, press it again. `Ctrl+Space` reads the selection aloud; `Ctrl+Alt+D` switches profile.

## Layout

```
ObertonCore/            Swift package, no UI: profiles, prompts, chunking, safety net, word diff,
                        AI back ends (Apple Intelligence, Ollama, Anthropic, OpenAI), speech, read aloud
Oberton/Shared/         SwiftUI app shared by Mac and iPhone: AppModel (the dictation state machine), pages
Oberton/macOS/          global hotkeys (Carbon), the overlay pill (non-activating panel), paste at the cursor
Oberton/iOS/            iPhone services (clipboard)
```

## Where it stands against Windows

| | Windows | Mac / iPhone |
|---|---|---|
| Speech recognition | Whisper (faster-whisper) | Apple Speech (`SpeechAnalyzer`, on-device) |
| AI cleanup | Ollama, Claude, OpenAI | **Apple Intelligence**, Ollama (Mac, user-installed), Claude, OpenAI |
| Profiles, prompts, safety net | ✓ | ✓ same text and rules |
| Insert at the cursor | ✓ | Mac ✓ (paste, clipboard restored); iPhone: clipboard |
| Overlay, live words, preview | ✓ | ✓ |
| Read aloud | Kokoro, Piper, Windows voices | system voices (Enhanced/Premium) |
| History, receipt with AI diff | ✓ | ✓ (no recordings yet) |
| Not yet | | Whisper (WhisperKit), Kokoro voice, type-as-you-speak, fits-the-surrounding-text, Extended Notes, Analytics, hotkey editor, iPhone keyboard |

## Toward TestFlight and the App Store

The app is already built the App Store way: sandboxed, hardened runtime, signed with your team (set `DEVELOPMENT_TEAM` in `Local.xcconfig`, copied from `Local.xcconfig.example`; git ignores it), bundle ID
`com.silentdiffusion.oberton`, no downloaded code (Apple's own speech and language models, Ollama only if the user runs it).
Left to do: register the bundle ID and create the app in App Store Connect, a real 1024 px icon (the current one is the
Windows `app.ico` scaled up), a privacy policy URL, then *Product › Archive* and upload for TestFlight.
