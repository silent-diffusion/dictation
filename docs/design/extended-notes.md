# Extended Notes (5.0.0)

Leave Oberton listening through a lecture or a meeting. It transcribes as it goes, tidies the text with the AI a
minute at a time, keeps a running summary and the recording, and lets you type your own notes straight into the text.
Agreed with the user on 2026-10-17; design mockup: https://claude.ai/artifact/47HGiQzukj2a1AzmTSKvVk

## Principles

- **Simple on screen, thorough in the background.** Every view is a plain text box. The AI's changes, the user's
  edits and notes, and the timing of the words are all recorded, but only the Edited tab shows them.
- **Same look as the rest of the app**: ink on paper, mono capitals, one accent, red only for recording.
- **Nothing is lost**: the session is saved to disk after every piece; the raw transcript and the audio are kept.
- **Never re-run the AI over the whole growing text**: each piece is formatted once. The summary is layered (5.1):
  every 5 to 10 minutes the new formatted text (never more than one AI request can take; the context is 4096 tokens) is
  summed up on its own; four summaries of a level are folded into one shorter one, and so on up, so what is left always
  fits one request however long the session runs; the Summary tab is written from what is left.

## Where it lives

- **Sidebar**: a new section **EXTENDED NOTES**, first under the Dashboard.
- **Landing page** (kept): before a session there is no title. The title's spot is an **EXTENDED NOTES SESSION** button
  with a hollow red ring that turns solid red once recording. Next to it: what to listen to: **Mic**, **Computer audio**
  or **Both** (remembered). Below: the list of past sessions (search, open, delete).
- **Session page**: header with the session title (click to rename, as everywhere), the red dot and the timer, and
  **Pause/Resume**, **Full screen**, **Export ▾** and **Stop**. Four tabs, in this order:
  1. **Transcript**: word for word as it is heard. A plain, editable text box; the user types their own notes anywhere.
  2. **Formatted**: tidied by the AI about every minute (punctuation, capitals, fillers out, paragraphs). Editable; the
     AI only ever appends new text after what is there, never overwrites the user's edits.
  3. **Summary**: never more than the main idea, three key points and three paragraphs; rewritten every 5 to 10 minutes
     from the section summaries. Editable; the user's version is handed to the next rewrite so their changes are kept.
  4. **Edited**: read-only, every change in colour: removed by the AI (grey, struck), added by the AI (accent), ¶ a
     paragraph break the AI made; removed by the user (amber, thick strike), changed by the user (amber bold on an
     amber wash), a note typed by the user (amber bold, underlined).
- **Playback bar** at the bottom, shown once the session has stopped: play/pause, position, a seek bar, **Skip
  silences**, 1× / 1.5× / 2×. ▶ plays from where the cursor is in the Transcript or Formatted text. The recording is
  played (and exported) with its level brought up, since mic recordings are quiet. **Right-click** in any tab: *Jump to
  this moment in the recording* (in the Summary tab, to the section the sentence is about).
- **Export ▾**: Transcript, Formatted, Summary, or everything, as .txt or .md; and the recording as .wav.
- **Dashboard**: a cell to the right of the signal path holding only a title and a text box that can always be typed
  in: the live transcript while a session records (the user edits and adds to it), and between sessions a notepad
  (kept in `data\notes\draft.txt`) that the next session begins with, as the user's own notes. Before a session, the
  title's spot is the **EXTENDED NOTES SESSION** button (hollow red ring, solid red once recording; clicking the red dot stops). A **Full screen** button opens the live session if
  one is recording, otherwise the Extended Notes landing page.

## Behaviour

- **Sources**: microphone, computer audio (WASAPI loopback, what the speakers play, for video calls), or both mixed.
  With the mic in use, the mic's clock paces the mix; computer audio alone is paced by a timer (loopback delivers
  nothing during silence).
- **Speech**: its own WebSocket connection to the already running speech engine (each connection is a separate session
  on the server, sharing the loaded model), in live mode: finished pieces arrive every few seconds. Committed audio is
  dropped on the server so an hour-long session doesn't grow in memory.
- **Normal dictation during a session** pauses the session (audio and transcription), which resumes when the dictation
  is done. Model unloading never happens while a session records.
- **AI**: formatting with the default AI model, about every minute of new speech; a failure keeps the text as heard.
  A section summary every 5 to 10 minutes of speech (then any merges, and the Summary tab rewritten), and once more at Stop.
- **Storage**: `data\notes\<yyyyMMdd-HHmmss>\session.json` and `audio.wav` (16 kHz mono, about 115 MB an hour; the wav
  header is refreshed with every save, so a crash keeps everything up to the last save).

## Data kept per session (session.json)

Title, start time, seconds recorded, sources; **Heard** (the recognizer's text, append-only); **Transcript** (Heard as
the user edited it); **Formatted** and **Summary** (as the user edited them); **Chunks** (for each formatting step:
the heard slice, the transcript slice sent to the AI, the AI's output, the start time); offsets of what has been
formatted and summarized; time anchors (text offset → seconds) for Transcript and Formatted, kept in step with the
user's edits.

## Later (not in 5.0.0)

Markers, speaker labels, organized views (lecture notes, minutes, action items), Word export.
