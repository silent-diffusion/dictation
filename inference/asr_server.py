"""
Local speech-recognition sidecar for the Dictation app.

Protocol (WebSocket on 127.0.0.1 only):
  client -> server
    text   {"type":"start","language":"en"|null,"prompt":"optional vocabulary hint"}
    binary raw PCM: 16 kHz, mono, signed 16-bit little endian
    text   {"type":"stop"}      -> server answers with one "final"
    text   {"type":"cancel"}    -> session discarded
  server -> client
    {"type":"ready","engine":"faster-whisper","model":...,"device":...,"compute_type":...}   (on connect)
    {"type":"partial","text":...}
    {"type":"final","text":...,"seconds":...}
    {"type":"error","code":...,"message":...}

Engines are pluggable: add a class with load()/transcribe(audio, final, language, prompt) and
register it in ENGINES (a Parakeet engine would slot in here).
Audio is held in memory only for the duration of a session and is never written to disk.
"""
import argparse
import asyncio
import json
import logging
import os
import re
import site
import sys
import time


def _add_cuda_dll_dirs():
    """Make the pip-installed NVIDIA cuBLAS / cuDNN DLLs visible to CTranslate2."""
    roots = list(site.getsitepackages())
    roots.append(os.path.join(os.path.dirname(os.path.dirname(sys.executable)), "Lib", "site-packages"))
    for root in roots:
        nv = os.path.join(root, "nvidia")
        if not os.path.isdir(nv):
            continue
        for sub in os.listdir(nv):
            b = os.path.join(nv, sub, "bin")
            if os.path.isdir(b):
                try:
                    os.add_dll_directory(b)
                except (OSError, AttributeError):
                    pass
                os.environ["PATH"] = b + os.pathsep + os.environ.get("PATH", "")


_add_cuda_dll_dirs()

import numpy as np  # noqa: E402

log = logging.getLogger("asr")
SAMPLE_RATE = 16000


MIN_SPEECH_SECONDS = 0.3  # less speech than this after the VAD counts as "nothing was said"


def has_content(text):
    return any(c.isalnum() for c in text)


def clean(text):
    """Collapse hallucinated runs of dots/ellipses such as ". . . . ." or "... ... ..."."""
    return re.sub(r"(?:\s*(?:\.{2,}|\u2026)\s*){2,}", " ", text).strip() if text else text



# Whisper's stock phrases on noise or silence (it learnt them from video subtitles). Kept when clearly said; dropped
# when Whisper itself doubts there was speech, or when a couple of words are stretched over seconds of audio.
PHANTOM_PHRASES = {
    "thank you", "thank you very much", "thank you so much", "thanks", "thanks for watching",
    "thank you for watching", "thanks for listening", "thank you for listening", "please subscribe", "you", "bye",
    "bye bye",
}
SUBTITLE_CREDIT = re.compile(r"^(subtitles?|captions?|transcri(bed|ption)|translat(ed|ion))\b.*\bby\b|amara\.org", re.I)


def norm(text):
    """Lower case, punctuation gone: for comparing phrases."""
    return re.sub(r"[^\w\s']", "", text.lower()).strip()


def is_phantom(seg):
    """A segment Whisper made up rather than heard (seg: a faster-whisper Segment)."""
    text = norm(seg.text)
    if not text:
        return True
    no_speech = getattr(seg, "no_speech_prob", 0.0) or 0.0
    logprob = getattr(seg, "avg_logprob", 0.0) or 0.0
    if (getattr(seg, "compression_ratio", 0.0) or 0.0) > 2.4:
        return True  # the same words over and over: a decoding loop
    if no_speech > 0.6 and logprob < -0.5:
        return True  # probably no speech, and unsure of the words
    if text in PHANTOM_PHRASES or SUBTITLE_CREDIT.search(seg.text.strip()):
        return no_speech > 0.2 or logprob < -0.6 or seg.end - seg.start > 2.5
    return False


# ----- evening out quiet speech -----
# Whisper's own speech detector (Silero VAD) skips speech that is much quieter than the rest, and Whisper itself hears
# words far below the loudest part of the audio poorly. A quiet microphone, or turning away from it, then loses whole
# sentences. So when the session asks for it ("even"), the audio is first levelled (every stretch of speech brought to
# about the same loudness) and the parts to decode are found by how far they stand above the room's noise floor,
# which works however quiet the microphone is. Silero, on the levelled audio, only decides whether anything was said
# at all (so silence still gives nothing, never a made-up "Thank you.").

FRAME = 320                 # 20 ms
TARGET_DB = -20.0           # where speech is brought to (dBFS, RMS)
MAX_BOOST_DB = 50.0         # never raise anything more than this
MAX_CUT_DB = 12.0           # nor lower it more than this
NOISE_MARGIN_DB = 8.0       # a frame this far above the noise floor counts as speech
NOISE_CEILING_DB = -55.0    # in the pauses, the noise floor is not raised above this


def _frame_db(audio):
    n = len(audio) // FRAME
    frames = audio[: n * FRAME].reshape(n, FRAME).astype(np.float64)
    return 20.0 * np.log10(np.maximum(np.sqrt((frames ** 2).mean(axis=1)), 1e-9))


def _noise_floor(rms_db):
    live = rms_db[rms_db > -90]  # digital silence (before the mic opens) isn't the room's noise
    return float(np.percentile(live, 10)) if len(live) >= 10 else None


def level(audio):
    """Bring every stretch of speech to about the same loudness, so quiet words aren't lost next to loud ones.

    The gain follows the speech's loudness (over about 0.4 s, so words keep their shape), is held through the pauses
    but limited there so background noise isn't raised to speech level, and changes smoothly: quickly down for a
    loud word after a quiet one, slower up. A soft limiter keeps peaks from clipping."""
    rms_db = _frame_db(audio)
    n = len(rms_db)
    floor = _noise_floor(rms_db) if n >= 10 else None
    if floor is None:
        return audio
    speech = rms_db > floor + NOISE_MARGIN_DB
    if speech.sum() < 5:
        return audio
    k = np.ones(21)
    count = np.convolve(speech.astype(np.float64), k, mode="same")
    power = np.convolve(np.where(speech, 10 ** (rms_db / 10), 0.0), k, mode="same")
    local = 10 * np.log10(np.maximum(power, 1e-18) / np.maximum(count, 1))
    gain = np.where(speech, TARGET_DB - local, np.nan)
    # Pauses take the gain of the speech before them (at the start, of the first speech).
    idx = np.where(speech, np.arange(n), -1)
    np.maximum.accumulate(idx, out=idx)
    idx[idx < 0] = int(np.argmax(speech))
    gain = np.clip(gain[idx], -MAX_CUT_DB, MAX_BOOST_DB)
    gain = np.where(speech, gain, np.minimum(gain, max(0.0, NOISE_CEILING_DB - floor)))
    smooth = np.empty(n)
    g = gain[0]
    for i in range(n):
        g += (gain[i] - g) * (0.5 if gain[i] < g else 0.15)
        smooth[i] = g
    lin = 10 ** (smooth / 20)
    out = audio.astype(np.float64)
    out[: n * FRAME] *= np.interp(np.arange(n * FRAME), np.arange(n) * FRAME + FRAME / 2, lin)
    out[n * FRAME:] *= lin[-1]
    a = np.abs(out)
    over = a > 0.9
    out[over] = np.sign(out[over]) * (0.9 + 0.1 * np.tanh((a[over] - 0.9) / 0.1))
    return out.astype(np.float32)


def speech_regions(audio, gap=0.5, pad=0.2, shortest=0.25):
    """Where words are being said, in samples: stretches well above the noise floor of the audio as recorded, joined
    across gaps of up to half a second, a little padding either side; blips shorter than a quarter second left out."""
    rms_db = _frame_db(audio)
    floor = _noise_floor(rms_db) if len(rms_db) >= 10 else None
    if floor is None:
        return []
    on = np.concatenate(([False], rms_db > floor + NOISE_MARGIN_DB, [False]))
    edges = np.flatnonzero(on[1:] != on[:-1])
    merged = []
    for a, b in zip(edges[::2], edges[1::2]):
        if merged and a - merged[-1][1] <= gap * SAMPLE_RATE / FRAME:
            merged[-1][1] = b
        else:
            merged.append([int(a), int(b)])
    out, p = [], int(pad * SAMPLE_RATE)
    for a, b in merged:
        if (b - a) * FRAME < shortest * SAMPLE_RATE:
            continue
        s, e = max(0, a * FRAME - p), min(len(audio), b * FRAME + p)
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], e)
        else:
            out.append((s, e))
    return out


def evened(audio):
    """The audio levelled and cut down to where words are said, with the regions it came from; None when nothing was
    said (Silero, on the levelled audio, finds less than MIN_SPEECH_SECONDS of speech)."""
    from faster_whisper.vad import VadOptions, get_speech_timestamps
    if len(audio) < SAMPLE_RATE * 0.3:
        return None
    levelled = level(audio)
    heard = get_speech_timestamps(levelled, VadOptions(min_silence_duration_ms=400))
    if sum(t["end"] - t["start"] for t in heard) < MIN_SPEECH_SECONDS * SAMPLE_RATE:
        return None
    regions = speech_regions(audio)
    if not regions:
        return None
    return np.concatenate([levelled[s:e] for s, e in regions]), regions


def original_time(t, regions):
    """A time in the joined audio (seconds), as a time in the audio it was cut from."""
    at, done = t * SAMPLE_RATE, 0
    for s, e in regions:
        if at <= done + (e - s):
            return (s + at - done) / SAMPLE_RATE
        done += e - s
    return regions[-1][1] / SAMPLE_RATE



def sentences(text):
    return [x for x in re.split(r"(?<=[.!?])\s+", (text or "").strip()) if x]


def collapse_repeats(text):
    """A sentence said three or more times in a row is kept once (Whisper's loops); said twice, it stays twice."""
    out, run = [], []
    for x in sentences(text) + [None]:
        if x is not None and run and norm(x) == norm(run[0]):
            run.append(x)
            continue
        out.extend(run[:1] if len(run) >= 3 else run)
        run = [x] if x is not None else []
    return " ".join(out)


class FasterWhisperEngine:
    name = "faster-whisper"

    def __init__(self, model, model_dir, device, compute_type):
        self.model_name = model
        self.model_dir = model_dir
        self.device = device
        self.compute_type = compute_type
        self.model = None

    def load(self, download=False):
        from faster_whisper import WhisperModel

        if download:
            WhisperModel(self.model_name, device="cpu", compute_type="int8", download_root=self.model_dir)
            return
        candidates = []
        if self.device in ("auto", "cuda"):
            candidates.append(("cuda", self.compute_type or "int8_float16"))
        if self.device in ("auto", "cpu"):
            candidates.append(("cpu", "int8" if self.device == "auto" or not self.compute_type else self.compute_type))
        last = None
        for dev, ct in candidates:
            try:
                m = WhisperModel(self.model_name, device=dev, compute_type=ct,
                                 download_root=self.model_dir, local_files_only=True)
                # Warm-up doubles as a check that the CUDA libraries really load.
                segs, _ = m.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), beam_size=1)
                list(segs)
                self.model, self.device, self.compute_type = m, dev, ct
                log.info("Loaded %s on %s (%s)", self.model_name, dev, ct)
                return
            except Exception as e:  # noqa: BLE001
                last = e
                log.warning("Could not load on %s: %s", dev, e)
        raise RuntimeError(f"Speech model could not be loaded: {last}")

    def _decode(self, audio, beam, vad, language, prompt, temperature, drop_phantoms=False):
        """Returns (text, seconds of speech the VAD kept, or None when the VAD was off)."""
        segs, info = self.model.transcribe(
            audio,
            language=language or None,
            beam_size=beam,
            vad_filter=vad,
            vad_parameters={"min_silence_duration_ms": 400},
            condition_on_previous_text=False,
            initial_prompt=prompt or None,
            temperature=temperature,
        )
        text = " ".join(s.text.strip() for s in segs if not (drop_phantoms and is_phantom(s))).strip()
        return text, (getattr(info, "duration_after_vad", None) if vad else None)

    def transcribe(self, audio, final, language, prompt, drop_phantoms=False, even=False):
        vad = True
        if even:
            prepared = evened(audio)
            if prepared is None:
                return ""  # nothing was said
            audio, vad = prepared[0], False  # already cut to the speech
        raw, speech = self._decode(audio, 5 if final else 1, vad, language, prompt, [0.0, 0.2, 0.4], drop_phantoms)
        text = clean(raw)
        if speech is not None and speech < MIN_SPEECH_SECONDS:
            # The VAD heard no speech. Decoding anyway (or retrying without the VAD) is exactly how Whisper
            # produces phantom "Thank you." / "Thanks for watching." on silence, so return nothing.
            return ""
        if final and not has_content(text):
            # Whisper sometimes emits only "..." on long/odd audio. Retry without VAD / with different decoding,
            # and as a last resort return nothing rather than junk.
            for beam, vad in ((1, False), (5, False)):
                text = clean(self._decode(audio, beam, vad, language, prompt, [0.0, 0.3, 0.6], drop_phantoms)[0])
                if has_content(text):
                    break
            else:
                log.warning("final decode produced no usable text for %.1fs of audio", len(audio) / SAMPLE_RATE)
                return ""
        return text if has_content(text) else ""

    def segments(self, audio, language, prompt, even=False):
        """Live mode: [(text, end_seconds)] for each phrase Whisper finds in the audio, silence skipped. A phrase it
        made up rather than heard (see is_phantom) comes back as ("", end), so its audio can still be let go of."""
        regions = None
        if even:
            prepared = evened(audio)
            if prepared is None:
                return []
            audio, regions = prepared
        segs, _ = self.model.transcribe(
            audio,
            language=language or None,
            beam_size=5 if self.device == "cuda" else 1,  # CPU: keep up with speech; the final pass redoes it anyway
            vad_filter=regions is None,
            vad_parameters={"min_silence_duration_ms": 400},
            condition_on_previous_text=False,
            initial_prompt=prompt or None,
            temperature=[0.0, 0.2, 0.4],
        )
        out = [("" if is_phantom(s) else clean(s.text.strip()), float(original_time(s.end, regions)) if regions else s.end) for s in segs]
        return [(t if has_content(t) else "", e) for t, e in out]


def choose_commit(segments, duration):
    """Live mode: how much of the pending audio to commit. Returns (text, end_seconds) or None.

    Prefers the last phrase that ends a sentence; after a long stretch without one, settles for the last
    phrase boundary. Phrases ending within the final COMMIT_MARGIN seconds may still be cut off, so they wait.
    """
    ready = [(t, e) for t, e in segments if e <= duration - COMMIT_MARGIN]
    if not ready:
        return None
    sentence_ends = [i for i, (t, _) in enumerate(ready) if t.rstrip("\"')").endswith((".", "!", "?"))]
    if sentence_ends:
        last = sentence_ends[-1]
    elif duration >= LIVE_FORCE_SECONDS:
        last = len(ready) - 1
    else:
        return None
    return " ".join(t for t, _ in ready[: last + 1] if t), ready[last][1]


ENGINES = {"faster-whisper": FasterWhisperEngine}

LIVE_CHUNK_SECONDS = 5.0     # live mode: look for something to commit once this much new audio has built up
LIVE_FORCE_SECONDS = 12.0    # ...and commit at a phrase boundary even without a sentence end after this long
LIVE_PARTIAL_SECONDS = 1.0   # live mode: refresh the running transcript of the uncommitted speech this often (GPU)
COMMIT_MARGIN = 0.8          # never commit a phrase ending this close to the newest audio: it may be cut off


class Session:
    PARTIAL_WINDOW = 28 * SAMPLE_RATE  # partials only look at the most recent ~28 s

    def __init__(self, ws, engine, gpu_lock):
        self.ws, self.engine, self.gpu_lock = ws, engine, gpu_lock
        self.chunks = []
        self.samples = 0
        self.language = None
        self.prompt = None
        self.active = False
        self.partial_task = None
        self.last_decoded = 0
        self.live = False
        self.drop_phantoms = False
        self.even = False
        self.committed = 0          # samples already committed (live mode)
        self.committed_text = ""
        self.dropped = 0            # live mode: committed samples already let go of (long sessions stay small)

    def audio(self):
        if not self.chunks:
            return np.zeros(0, dtype=np.float32)
        pcm = np.frombuffer(b"".join(self.chunks), dtype=np.int16)
        return pcm.astype(np.float32) / 32768.0

    async def send(self, obj):
        await self.ws.send(json.dumps(obj))

    def prompt_for(self):
        """The vocabulary hint plus the end of what was committed, with repeats and stock phrases left out: fed back
        to Whisper, those would prime it to make up more of them."""
        recent = [x for x in sentences(collapse_repeats(self.committed_text[-600:])) if norm(x) not in PHANTOM_PHRASES]
        tail = " ".join(recent)[-200:]
        return " ".join(p for p in (self.prompt, tail) if p) or None

    def new_text(self, text):
        """What a commit adds: Whisper's loops collapsed, and nothing at all when it only repeats a stock phrase that was
        just committed (the "Thank you. Thank you. Thank you." of a quiet room)."""
        text = collapse_repeats(text)
        said = [norm(x) for x in sentences(text)]
        before = sentences(self.committed_text[-200:])
        if said and before and all(x in PHANTOM_PHRASES for x in said) and set(said) == {norm(before[-1])}:
            return ""
        return text

    async def _partial_loop(self):
        loop = asyncio.get_running_loop()
        while self.active:
            await asyncio.sleep(0.25)
            if self.samples - self.last_decoded < SAMPLE_RATE * 0.6 or self.samples < SAMPLE_RATE * 0.5:
                continue
            self.last_decoded = self.samples
            audio = self.audio()[-self.PARTIAL_WINDOW:]
            try:
                async with self.gpu_lock:
                    if not self.active:
                        break
                    text = await loop.run_in_executor(
                        None, self.engine.transcribe, audio, False, self.language, self.prompt, False, self.even)
                if self.active and text:
                    await self.send({"type": "partial", "text": text})
            except Exception as e:  # noqa: BLE001
                log.exception("partial failed")
                await self.send({"type": "error", "code": "partial_failed", "message": str(e)})

    async def _live_loop(self):
        """Live mode: every few seconds, commit the finished sentences of the audio not yet committed. In between, send
        the running transcript of the rest as a "partial", so the user can watch the words come in."""
        loop = asyncio.get_running_loop()
        # On a CPU every decode takes longer, so the running transcript refreshes less often.
        interval = LIVE_PARTIAL_SECONDS if self.engine.device == "cuda" else LIVE_PARTIAL_SECONDS * 2.5
        last = 0
        while self.active:
            await asyncio.sleep(0.25)
            pending = self.samples - self.committed
            if self.samples - last < SAMPLE_RATE * interval or pending < SAMPLE_RATE * 0.6:
                continue
            last = self.samples
            due_commit = pending >= SAMPLE_RATE * LIVE_CHUNK_SECONDS
            audio = self.audio()[self.committed:]
            # The text committed so far (plus the vocabulary hint) keeps casing and names consistent across pieces.
            prompt = self.prompt_for()
            try:
                async with self.gpu_lock:
                    if not self.active:
                        break
                    segs = await loop.run_in_executor(None, self.engine.segments, audio, self.language, prompt, self.even)
            except Exception as e:  # noqa: BLE001
                log.exception("live decode failed")
                await self.send({"type": "error", "code": "live_failed", "message": str(e)})
                continue
            if not self.active:
                break
            pick = choose_commit(segs, len(audio) / SAMPLE_RATE) if due_commit else None
            release = 0
            if pick:
                text, end = pick
                release = int(end * SAMPLE_RATE)
                text = self.new_text(text)
                if text:
                    self.committed_text = (self.committed_text + " " + text).strip()
                    await self.send({"type": "commit", "text": text})
                segs = [(t, e) for t, e in segs if e > end]
            elif due_commit and not any(t for t, _ in segs) and len(audio) >= SAMPLE_RATE * LIVE_FORCE_SECONDS:
                # Nothing heard for a while (silence, or only made-up phrases): let go of that audio too, keeping the
                # last moments in case speech is just starting.
                release = len(audio) - int((COMMIT_MARGIN + 1.0) * SAMPLE_RATE)
                segs = []
            if release > 0:
                self.committed += release
                # Committed audio is never decoded again: let go of it, so an hour-long session (Extended Notes) doesn't
                # keep, and re-join on every pass, everything said since it began.
                drop = self.committed
                pcm = b"".join(self.chunks)
                self.chunks = [pcm[drop * 2:]]
                self.samples -= drop
                self.dropped += drop
                self.committed = 0
                last = max(0, last - drop)
            await self.send({"type": "partial", "text": " ".join(t for t, _ in segs if t).strip()})

    def start(self, msg):
        self.chunks, self.samples, self.last_decoded = [], 0, 0
        self.language = msg.get("language") or None
        self.prompt = msg.get("prompt") or None
        self.live = bool(msg.get("live"))
        # Extended Notes transcribing a recording again, part by part: Whisper's made-up phrases dropped as in live mode.
        self.drop_phantoms = bool(msg.get("drop_phantoms"))
        # Even out quiet speech before decoding (see evened); Settings › Speech, on by default.
        self.even = bool(msg.get("even"))
        self.committed, self.committed_text, self.dropped = 0, "", 0
        self.active = True
        self.partial_task = asyncio.create_task(self._live_loop() if self.live else self._partial_loop())

    async def stop(self):
        self.active = False
        if self.partial_task:
            await self.partial_task
        t0 = time.time()
        audio = self.audio()
        text = tail = ""
        loop = asyncio.get_running_loop()
        rest = audio[self.committed:]
        if self.live and (self.committed or self.dropped):
            # Live mode: the committed pieces are already transcribed, so only the speech after the last one is
            # decoded. The final transcript is those pieces plus this tail; nothing is transcribed twice.
            if len(rest) >= SAMPLE_RATE * 0.3:
                prompt = self.prompt_for()
                async with self.gpu_lock:
                    tail = await loop.run_in_executor(None, self.engine.transcribe, rest, True, self.language, prompt, True, self.even)
                tail = self.new_text(tail)
            text = (self.committed_text + " " + tail).strip()
        elif len(audio) >= SAMPLE_RATE * 0.3:
            async with self.gpu_lock:
                text = await loop.run_in_executor(
                    None, self.engine.transcribe, audio, True, self.language, self.prompt, self.live or self.drop_phantoms, self.even)
            if self.live or self.drop_phantoms:
                text = collapse_repeats(text)
            tail = text if self.live else ""
        secs = (len(audio) + self.dropped) / SAMPLE_RATE
        self.chunks, self.samples, self.committed, self.dropped = [], 0, 0, 0  # discard audio
        await self.send({"type": "final", "text": text, "tail": tail, "seconds": round(secs, 2),
                         "decode_ms": int((time.time() - t0) * 1000)})

    def cancel(self):
        self.active = False
        self.chunks, self.samples = [], 0


async def serve(args, engine):
    from websockets.asyncio.server import serve as ws_serve

    gpu_lock = asyncio.Lock()

    async def handler(ws):
        s = Session(ws, engine, gpu_lock)
        await s.send({"type": "ready", "engine": engine.name, "model": engine.model_name,
                      "device": engine.device, "compute_type": engine.compute_type})
        try:
            async for msg in ws:
                if isinstance(msg, bytes):
                    if s.active:
                        s.chunks.append(msg)
                        s.samples += len(msg) // 2
                    continue
                data = json.loads(msg)
                t = data.get("type")
                if t == "start":
                    s.start(data)
                elif t == "stop":
                    await s.stop()
                elif t == "cancel":
                    s.cancel()
        except Exception:  # noqa: BLE001
            log.exception("connection error")
        finally:
            s.cancel()

    async with ws_serve(handler, "127.0.0.1", args.port, max_size=2**24, origins=[None]):  # no browser (Origin) clients
        print(f"READY port={args.port} device={engine.device}", flush=True)
        await asyncio.Future()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--engine", default="faster-whisper", choices=list(ENGINES))
    p.add_argument("--model", default="large-v3-turbo")
    p.add_argument("--model-dir", required=False)
    p.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    p.add_argument("--compute-type", default="")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--download", action="store_true", help="download the model (needs internet) and exit")
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    model_dir = args.model_dir or os.path.join(os.environ.get("DICTATION_ROOT", "."), "models", "whisper")
    os.makedirs(model_dir, exist_ok=True)
    if not args.download:
        os.environ["HF_HUB_OFFLINE"] = "1"  # hard guarantee: no network at runtime
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

    engine = ENGINES[args.engine](args.model, model_dir, args.device, args.compute_type)
    try:
        engine.load(download=args.download)
    except Exception as e:  # noqa: BLE001
        print(f"ERROR model_load_failed: {e}", flush=True)
        sys.exit(2)
    if args.download:
        print("Model downloaded to", model_dir)
        return
    asyncio.run(serve(args, engine))


if __name__ == "__main__":
    main()
