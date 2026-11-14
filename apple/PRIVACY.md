# Oberton for Mac and iPhone: privacy policy

*Last updated 7 November 2026. This covers the Mac app (from the App Store, and the direct download from GitHub) and the
iPhone and iPad app. The Windows app has its own section in the main README.*

**In short: Oberton works on your device.** Your voice is turned into text on your Mac or iPhone, the text is tidied up
by an AI model on your device, and everything Oberton keeps stays in a folder on your device. Oberton has no account,
no server of its own, no analytics, no tracking and no crash reporting. The developer never receives anything you say,
type or record.

## What happens to your voice and your words

- **Speech recognition runs on your device.** Oberton uses Apple's on-device speech recognizer or a Whisper model that
  runs on your device. Audio is never sent anywhere for recognition.
- **The AI clean-up runs on your device by default.** It uses Apple Intelligence's on-device model, or a model run by
  Ollama on your own Mac. "Keep everything offline" (Settings › Cloud AI) is on from the start and blocks every cloud
  model.
- **Cloud AI is your choice, with your own account.** If you turn off "Keep everything offline", add your own API key
  for Anthropic or an OpenAI-compatible service, and pick a cloud model for a profile, Oberton sends that service
  the text it is asked to tidy up (the dictation you just made, or the part of an Extended Notes transcript being
  formatted or summarized) with the profile's instructions. Nothing else goes with it: no recordings, no history, no
  device identifiers. The same goes for Ollama's own cloud models (names ending in "cloud"), which run on ollama.com.
  What the provider does with the text is set by your agreement with it. Your keys are kept in the Keychain on your
  device, never in Oberton's files.
- **The text around your cursor** (direct download only, with Accessibility allowed) is read only to fit spacing and
  capitals around what you dictate. It is never stored or sent to an AI model.

## What Oberton keeps, and where

Everything is in Oberton's data folder:

- **Mac, App Store build:** `~/Library/Containers/com.silentdiffusion.oberton/Data/Library/Application Support/Oberton`
- **Mac, direct download:** `~/Library/Application Support/Oberton`
- **iPhone and iPad:** inside the app; the Files app doesn't show it.

On the Mac, Settings › Advanced › *Open data folder* shows it.

| What | File | Kept for |
|---|---|---|
| **History:** each dictation's words, the AI's edit, what was inserted, the app (and in the direct download, the window title) it went into, and its recording | `history/` | Until you delete it, or the limits you set in Settings › History. Recordings: 7 days unless you change it. |
| **Extended Notes sessions:** transcript, formatted text, summary, your own notes and the recording | `notes/<date>/session.json` and `audio.wav` | Until you delete the session |
| **Counts:** words dictated per day, per app and per site; the most used words and phrases; Extended Notes' daily totals | `usage.json`, `words.json`, `notes/usage.json` | Until you reset them (Settings › History resets the dictation counts and the word tally; the notes totals go with the data folder) |
| **Settings and profiles** | `settings.json`, `profiles.json` | While Oberton is installed |
| **Log:** what Oberton did (starts, errors, timings, the names of the app you dictated into and of a microphone that wasn't found; never what you said) | `logs/dictation.log` and one older copy, 2 MB each | Rolls over by itself |
| **Downloaded models and voices** | `models/` | Until you remove them in Settings › Models |

**Window titles (direct download only).** History notes the title of the window you dictated into (for example a
browser tab's title), so you can see where text went and Analytics can count sites. The App Store build doesn't read
window titles at all.

**Temporary copies.** A few copies of recordings live for a moment in the system's temporary folder, outside the data
folder: the levelled copy Extended Notes plays back, the copy a History *Run again* reads, and on the Mac the file put
on the clipboard by *Copy recording*. They are removed when they are no longer needed, and whatever a crash leaves
behind is removed the next time Oberton starts (the clipboard copy a day later, so it can still be pasted).

**On iPhone and iPad,** History and Extended Notes files are encrypted by iOS until the device is first unlocked after a restart,
and Extended Notes recordings are left out of iCloud and computer backups (they can hold other people's voices and are
large). Your notes' text, and History, are backed up with the rest of your device.

**On the Mac,** your disk encryption (FileVault) protects these files, and Extended Notes recordings are left out of
Time Machine.

## The clipboard

Oberton pastes your dictation through the clipboard when typing it isn't possible, then puts back what was there.

- **Mac:** the dictation is marked as temporary and concealed, so clipboard managers that follow the common convention
  leave it out of their history.
- **iPhone and iPad:** a dictation is copied for you to paste. It stays on this device only (not shared through
  Universal Clipboard) and leaves the clipboard after 2 minutes; text you copy with a COPY button leaves it after 10.

## What goes over the internet, and when

Oberton connects to the internet only for these, each started by you or shown with a progress bar:

- **Model and voice downloads,** when you choose them in Settings › Models or the first-run setup: Whisper models from
  Hugging Face (`argmaxinc/whisperkit-coreml`), Read aloud voices from GitHub (Kokoro) and Hugging Face (Piper), and the
  word lists the Kokoro voice uses from GitHub. Apple's speech recognizer may download its language files through
  macOS or iOS. These are ordinary downloads; nothing about you is sent with them.
- **Ollama (direct download only):** Oberton can download the Ollama runtime from GitHub and AI models through Ollama
  from ollama.com. Ollama then runs on your Mac.
- **Cloud AI,** only as described above.
- **Update checks (direct download only):** Oberton asks GitHub whether there is a newer version (at start, which you
  can turn off in Settings › Updates, and when you press *Check for updates*). It sends no information about your Mac
  (Sparkle's system profile is off). The App Store build is updated by the App Store.

## Deleting your data

- **One dictation or session:** delete it in History or Extended Notes; its recording goes with it.
- **All history:** Settings › History › *Delete all history…*
- **Everything:** quit Oberton and delete its data folder (above). On iPhone and iPad, deleting the app deletes it all.
  Your API keys are removed in Settings › Cloud AI.

## Children

Oberton isn't directed at children and collects nothing from anyone.

## Changes and contact

If this policy changes, the new version is published here with a new date. Questions: open an issue on the project's
GitHub page.
