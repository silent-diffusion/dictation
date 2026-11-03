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

Open `Oberton.xcodeproj` in Xcode 27 and run the **Oberton** scheme on *My Mac* or an iPhone (or **Oberton Direct**, the
Mac download outside the App Store; see below). From the command line:

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

## The direct download (Developer ID)

The Mac app also ships outside the App Store, as Windows does: the **Oberton Direct** scheme (its own target, sharing
every source file). It is signed with Developer ID and notarized, **not sandboxed**, so it can do what the App Store build
can't: read the text around another app's cursor through Accessibility (`Distribution.axTrusted`; such features check
`Distribution.isDirect` and the App Store build hides them or falls back) and update itself with
[Sparkle](https://sparkle-project.org) (2.10.0, pinned exactly; only this target links it). Settings › Updates then works
as on Windows: CHECK FOR UPDATES, DOWNLOAD AND INSTALL (N MB), and a check 20 seconds after start when "Check for
updates when Oberton starts" is on. The App Store build keeps its information page.

| | App Store (`Oberton`) | Direct (`Oberton Direct`) |
|---|---|---|
| Settings | Xcode project + `Signing.xcconfig` | `Direct.xcconfig` (includes `Signing.xcconfig`) |
| Sandbox / entitlements | on / `Oberton.entitlements` | off / `Oberton-Direct.entitlements` (microphone) |
| Info.plist | `Info.plist` | `Info-Direct.plist`: the same Mac keys (CI checks with `scripts/check-direct-plist.sh`) + Sparkle's |
| Swift flag | — | `OBERTON_DIRECT` |
| Data | `~/Library/Containers/com.silentdiffusion.oberton/…/Application Support/Oberton` | `~/Library/Application Support/Oberton` |

Both build `Oberton.app` with the same bundle ID, so in Xcode's shared DerivedData the last one built replaces the other;
on the command line give the direct build its own folder:

```bash
xcodebuild -project Oberton.xcodeproj -scheme "Oberton Direct" -destination 'platform=macOS' -derivedDataPath build-direct -allowProvisioningUpdates build
```

**Releasing** (nothing here publishes anything):

1. Once: a *Developer ID Application* certificate for your team in the login keychain, and notarization credentials in
   the keychain: `xcrun notarytool store-credentials oberton-notary --apple-id <Apple ID> --team-id <team>` (it asks for an
   app-specific password). The script also takes an App Store Connect API key or an Apple ID from the environment
   (`NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER`, or `NOTARY_APPLE_ID`/`NOTARY_PASSWORD`); credentials are never written to the repo.
2. Once: Sparkle's update signing key. Run `generate_keys` from Sparkle's `bin` folder (in DerivedData,
   `SourcePackages/artifacts/sparkle/Sparkle/bin`); the private key stays in your keychain. Put the public key in
   `OBERTON_SPARKLE_PUBLIC_KEY` and the feed's address in `OBERTON_APPCAST_URL` (`Direct.xcconfig`; both are placeholders
   now, and without the key the updater doesn't start).
3. Each release: raise `MARKETING_VERSION` (kept equal to the Windows version) and `CURRENT_PROJECT_VERSION`, then
   `scripts/export-direct.sh`: archive, Developer ID export, checks (Developer ID, hardened runtime, no sandbox),
   notarization, stapling, and `build-direct/Oberton-<version>.zip`. `--no-notarize` stops after the signed export.
4. Sign the zip and write `appcast.xml` with `generate_appcast build-direct/`, then upload both where the feed points.

## Privacy check before pushing

`../scripts/privacy-check.sh` looks through the commits not yet on a remote (or any range: `../scripts/privacy-check.sh
origin/main..`) for personal paths, this Mac's user and host names, the team ID from `Local.xcconfig`, keys and tokens,
non-noreply e-mail addresses, and files that never belong in git (signing material, recordings, Xcode user state). It is
not installed as a hook; to run it on every push, from the repository's root:

```bash
ln -s ../../scripts/privacy-check.sh "$(git rev-parse --git-common-dir)/hooks/pre-push"
```
