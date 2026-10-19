# Extended Notes (5.0.0, markers / Word export / usage in 5.2.0)

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
- **Export ▾**: Transcript, Formatted, Summary, or everything, as .txt or .md, or as Word (.docx, written by the app
  itself, no library); and the recording as .wav. *Everything* lists the markers.
- **Markers** (5.2): **⚑ Mark** in the session header, or the marker hotkey (Settings › Hotkeys, default `Ctrl+Alt+M`),
  appends `⚑ h:mm:ss` on its own line to the Transcript at the moment of the recording, with a time anchor, and keeps
  the marker in session.json. The formatting prompt tells the AI to keep marker lines exactly.
- **Usage** (5.2): the landing page shows a strip from `data\notes\usage.json`: last 30 days and all time.
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
  None of it starts while a dictation runs, so a dictation's AI edit never waits behind a long notes request.
- **Statistics** (5.1.1): Extended Notes never count in the dictation statistics (dashboard, Analytics, History); a
  lecture's hour and its ten thousand words are not dictation. Their own daily counts (sessions, seconds, words heard
  and typed, AI requests, by source; never text) are kept apart in `data\notes\usage.json` for later.
- **Speech engine not ready**: audio that arrives while the engine loads or reconnects waits (up to three minutes) and
  is sent once it is connected, so the transcript has no gap; a failed connection is retried 5, 10, 20… seconds later,
  up to a minute apart.
- **Playback copy**: the louder copy is made once per session and kept in `%TEMP%\oberton-notes\<id>.wav` (with its
  pauses in `<id>.json`; deleted with the session), so a session opens ready to play.
- **Storage**: `data\notes\<yyyyMMdd-HHmmss>\session.json` and `audio.wav` (16 kHz mono, about 115 MB an hour; the wav
  header is refreshed with every save, so a crash keeps everything up to the last save).

## Data kept per session (session.json)

Title, start time, seconds recorded, sources; **Heard** (the recognizer's text, append-only); **Transcript** (Heard as
the user edited it); **Formatted** and **Summary** (as the user edited them); **Chunks** (for each formatting step:
the heard slice, the transcript slice sent to the AI, the AI's output, the start time); offsets of what has been
formatted and summarized; time anchors (text offset → seconds) for Transcript and Formatted, kept in step with the
user's edits.

## Later (not in 5.0.0)

Speaker labels, organized views (lecture notes, minutes, action items). Markers and Word export shipped in 5.2.0.

## Formatting safeguards (5.2.4)

Found in a real 47-minute session (18 Oct 2026, a quiet mic plus computer audio, qwen3:4b): in 14 of 32 formatting steps
the model formatted the text and then ran on until it was cut off (rows of "⚠️ 00:03:15", "⌋", stray Chinese characters:
432 of the Formatted text's 524 lines), copied the speech engine's "Thank you." loop (82 times in what was heard, once
41 in a row), added labels ("listener note:") and changed a number ("1550" to "155-0"). Now:

- **Speech engine** (`asr_server.py`): a stock phrase ("Thank you.", "Thanks for watching") is dropped when Whisper
  doubts there was speech or it is stretched over seconds; loops (a sentence three or more times in a row, or a
  segment with a high compression ratio) are collapsed; a stock phrase that only repeats the one just committed is
  dropped; repeats and stock phrases are kept out of the prompt fed back to Whisper; and stretches with nothing heard
  are let go of, so silence doesn't pile up.
- **Before the AI**: loops are collapsed (`NotesFormat.CollapseRepeats`). The instructions mention typed lines and markers
  only when the text has them (mentioned anyway, the model invented its own), and the reply is limited to about the
  text's length.
- **After the AI** (`NotesFormat.Accept`): junk lines, emoji and symbols (and Chinese, Japanese or Korean script the
  text hasn't got), invented markers, timestamps and labels come out, split lines are joined back. A reply that drops
  most of the text, adds more than a few words (a tenth of the text) or has a number the text hadn't is rejected: that part is kept as heard.
- **Old sessions** are repaired once when loaded (`NotesFormat.Repair`): junk lines and loops come out of the Formatted
  text and the formatting steps, one edit at a time so anchors and the user's edits stay.
- A part that carries on a sentence the last one left open joins it instead of starting a paragraph; summary paragraphs
  lose labels like "What was decided:".

## The AI model (5.3.0)

Extended Notes has its own AI model setting (Settings › Models › *Extended Notes · AI*, and *AI model* on the start
card; one setting, `NotesModel`). The default is **Best on this PC**: the installed model with the most parameters that
fits in the GPU's memory (without an NVIDIA GPU, up to 4.5B), then the larger file; never an embedding model, or one of Ollama's cloud models (they run on ollama.com). It can also
follow the active model, name an installed model, or a cloud model (which sends the transcript to that service). A
model chosen by name that is no longer installed falls back to the best one. The recorder resolves the setting when a
session starts, when it changes, and every ten minutes, and logs the model it uses. Found on 18 Oct 2026: the notes had
used the active model (qwen3:4b) while the user's profiles use qwen2.5:7b, which on that 6 GB GPU is the best fit, and
is what dictation already loads, so the two no longer swap models in memory.

## Reading view and the pipeline (5.4.0)

- The Transcript, Formatted and Summary tabs, and the dashboard's notes box, show their text rendered as Markdown
  (`NotesMarkdown`, `MarkdownPresenter`): headings, bullet and numbered lists, quotes, code, rules, **bold**, *italic*,
  `code`, links as their text, ⚑ markers in the accent, and a short label at the start of a line ("Main idea:") in bold.
  Line breaks are kept as typed. A click turns the view back into the plain text box with the cursor at that place;
  typing while reading goes on at the end; leaving the box shows the rendered text again. Right-click on the rendered text
  finds the same place in the plain text (each run carries its source offset), so the jump to the recording still works.
- At the top of Extended Notes (the landing page and a session), a signal path of its own (`NotesPipeline`): LISTEN (the
  source) → SPEECH (the speech model) → FORMAT and SUMMARY (the AI model). A step lights in the accent, its core pulsing,
  while it works: recording, transcribing, formatting now, summing up now; between steps it shows what is waiting (words
  to format, how far to the next summary section). Each step opens its settings page.
