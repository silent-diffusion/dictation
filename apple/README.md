# Oberton for Mac and iPhone

A native SwiftUI port of Oberton: one codebase for macOS 26+ and iOS 26+. The same profiles, prompts, examples and
safety net as the Windows app, with one addition: **Apple Intelligence** (Apple's on-device model) as an AI choice, and the
default where it is available. Nothing to install, nothing leaves the device.

```
MIC ──→ SPEECH ──→ AI ──→ INSERT
        Whisper (WhisperKit)  Apple Intelligence · Ollama · Claude · OpenAI   at the cursor (Mac) / clipboard (iPhone)
        or Apple Speech       (profiles)                                       ┆
        (on-device)                                                            └┄┄ READ ALOUD  Kokoro, Piper, system voices
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

On first launch the setup window asks for the **microphone** and for **Accessibility** (to paste at the cursor; in the
direct download also to read the text around the cursor, the selection and window titles) and downloads the speech model.
Then press `Ctrl+D` in any app, speak, press it again. `Ctrl+Space` reads the selection aloud; `Ctrl+Alt+D` switches
profile. The app lives in the menu bar; closing the window keeps it running. If macOS's own "Select the previous input
source" shortcut is on, `Ctrl+Space` may switch the keyboard layout instead: setup and *Settings › Hotkeys* say so and
offer another key for Read aloud with one click.

### Updating

The direct download: *Settings › Updates › Check for updates* (or the menu bar's *Check for updates…*). If there's a newer
release it downloads it and updates in place; your settings, profiles and downloaded models are kept. *Check for updates
when Oberton starts* is on by default (turn it off there to make no network request at all unless you ask). The App
Store build updates through the App Store (or TestFlight).

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
| Speech recognition | Whisper (faster-whisper) | Whisper (WhisperKit, the same models) or Apple Speech (`SpeechAnalyzer`), on-device |
| AI cleanup | Ollama, Claude, OpenAI | **Apple Intelligence**, Ollama (direct download: its own copy; App Store: user-installed), Claude, OpenAI |
| Profiles, prompts, safety net | ✓ | ✓ same text and rules |
| Insert at the cursor | ✓ | Mac ✓ (paste, clipboard restored); iPhone: clipboard |
| Overlay, live words, preview, type as you speak | ✓ | ✓ |
| Fit dictation into the surrounding text, window titles, sites | ✓ | Mac direct download (Accessibility) |
| Read aloud | Kokoro, Piper, Windows voices | Kokoro, Piper, system voices |
| History (with recordings), Analytics, Extended Notes, hotkey editor | ✓ | ✓ |
| Updates | Settings › Updates | direct download: Settings › Updates (Sparkle); App Store build: the App Store / TestFlight |
| Not yet | | iPhone keyboard (inserting into other iPhone apps) |

Settings, profiles, History and notes are kept in `~/Library/Application Support/Oberton` (the App Store build: inside its
container), with the log in `logs/dictation.log` (*Settings › Advanced › Open logs*). Their files are not interchangeable
with the Windows app's (different key names and date formats).

**Troubleshooting:** if the first-run setup fails, check your internet connection and click *Continue setup*; it picks up
where it stopped. If a hotkey does nothing or the overlay says it is "already used", another app owns it: pick another on
*Settings › Hotkeys*. If a dictation is only copied and Oberton says to allow it in Accessibility although the switch
there is on, the switch belongs to another signed copy of Oberton (an older or development build): quit Oberton, run
`tccutil reset PostEvent com.silentdiffusion.oberton` and `tccutil reset Accessibility com.silentdiffusion.oberton`,
open Oberton, dictate once and allow it again, then quit and reopen it. Anything else: the log above.

## Toward TestFlight and the App Store

The app is already built the App Store way: sandboxed, hardened runtime, signed with your team (set `DEVELOPMENT_TEAM` in `Local.xcconfig`, copied from `Local.xcconfig.example`; git ignores it), bundle ID
`com.silentdiffusion.oberton`, no downloaded code (Apple's own speech and language models, Ollama only if the user runs it).
Debug builds (both schemes) are `com.silentdiffusion.oberton.dev`, so a development copy never shares Privacy & Security
grants, the sandbox container, settings or Keychain items with the installed App Store or TestFlight copy (macOS ties
those grants to the bundle ID and the signature; CI checks the IDs with `scripts/check-bundle-ids.sh`).
Left to do: register the bundle ID and create the app in App Store Connect, a privacy policy URL, then *Product › Archive* and upload for TestFlight.

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
| Data | `~/Library/Containers/com.silentdiffusion.oberton/…/Application Support/Oberton` (Debug: `…oberton.dev/…`) | `~/Library/Application Support/Oberton` (Debug too: not sandboxed) |

Both build `Oberton.app` with the same bundle ID, so in Xcode's shared DerivedData the last one built replaces the other
(and a Debug App Store build made over a direct one keeps a stale, unused `Sparkle.framework` inside; archives are
clean). On the command line give the direct build its own folder:

```bash
xcodebuild -project Oberton.xcodeproj -scheme "Oberton Direct" -destination 'platform=macOS' -derivedDataPath build-direct -allowProvisioningUpdates build
```

**Releasing** (nothing here publishes anything):

1. Once: a *Developer ID Application* certificate for your team in the login keychain, and notarization credentials in
   the keychain: `xcrun notarytool store-credentials oberton-notary --apple-id <Apple ID> --team-id <team>` (it asks for an
   app-specific password). The script also takes an App Store Connect API key or an Apple ID from the environment
   (`NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER`, or `NOTARY_APPLE_ID`/`NOTARY_PASSWORD`); credentials are never written to the repo.
2. The update signing key (done): an EdDSA key pair made with Sparkle's `generate_keys` (in DerivedData,
   `SourcePackages/artifacts/sparkle/Sparkle/bin`). The **public** key is `OBERTON_SPARKLE_PUBLIC_KEY` in
   `Direct.xcconfig` (it becomes `SUPublicEDKey` in `Info-Direct.plist`). The **private** key exists only in the login
   keychain of the Mac that made it (item "Private key for signing Sparkle updates", account `ed25519`); it is never
   written to this repository or to a file. `generate_keys -p` prints the public key again. To release from another
   Mac, move the key with `generate_keys -x <file>` there and `-f <file>` on the other Mac, then delete the file; if the
   key is lost, every installed copy has to be updated by hand once (a new key means a new public key in a new build).
   `scripts/export-direct.sh` stops when the public key is empty.
3. **The appcast address is a placeholder.** `OBERTON_APPCAST_URL` in `Direct.xcconfig` points at
   `…/releases/download/mac-appcast/appcast.xml`, where nothing is published; until a feed exists a check finds nothing
   and says "You're up to date". Decide where the Mac feed lives before the first direct release. It must not be the
   repository's `releases/latest`, which is the Windows release. Release notes: write the item's `<description>` as
   plain text with `sparkle:format="plain-text"` to show them as Windows shows a GitHub release's text (HTML is turned
   into plain text).
4. Each release: raise `MARKETING_VERSION` (kept equal to the Windows version, in three parts) and
   `CURRENT_PROJECT_VERSION`, then `scripts/export-direct.sh`: archive, Developer ID export, checks (Developer ID,
   hardened runtime, no sandbox), notarization, stapling, and `build-direct/Oberton-<version>.zip`. `--no-notarize`
   stops after the signed export.
5. Sign the zip and write `appcast.xml` with `generate_appcast build-direct/` (it signs with the keychain's key), then
   upload both where the feed points.

## Privacy check before pushing

`../scripts/privacy-check.sh` looks through the commits not yet on a remote (or any range: `../scripts/privacy-check.sh
origin/main..`) for personal paths, this Mac's user and host names, the team ID from `Local.xcconfig`, keys and tokens,
non-noreply e-mail addresses, and files that never belong in git (signing material, recordings, Xcode user state). It is
not installed as a hook; to run it on every push, from the repository's root:

```bash
ln -s ../../scripts/privacy-check.sh "$(git rev-parse --git-common-dir)/hooks/pre-push"
```
