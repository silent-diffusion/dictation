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

    def _decode(self, audio, beam, vad, language, prompt, temperature):
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
        text = " ".join(s.text.strip() for s in segs).strip()
        return text, (getattr(info, "duration_after_vad", None) if vad else None)

    def transcribe(self, audio, final, language, prompt):
        raw, speech = self._decode(audio, 5 if final else 1, True, language, prompt, [0.0, 0.2, 0.4])
        text = clean(raw)
        if speech is not None and speech < MIN_SPEECH_SECONDS:
            # The VAD heard no speech. Decoding anyway (or retrying without the VAD) is exactly how Whisper
            # produces phantom "Thank you." / "Thanks for watching." on silence, so return nothing.
            return ""
        if final and not has_content(text):
            # Whisper sometimes emits only "..." on long/odd audio. Retry without VAD / with different decoding,
            # and as a last resort return nothing rather than junk.
            for beam, vad in ((1, False), (5, False)):
                text = clean(self._decode(audio, beam, vad, language, prompt, [0.0, 0.3, 0.6])[0])
                if has_content(text):
                    break
            else:
                log.warning("final decode produced no usable text for %.1fs of audio", len(audio) / SAMPLE_RATE)
                return ""
        return text if has_content(text) else ""

    def segments(self, audio, language, prompt):
        """Live mode: [(text, end_seconds)] for each phrase Whisper finds in the audio, silence skipped."""
        segs, _ = self.model.transcribe(
            audio,
            language=language or None,
            beam_size=5 if self.device == "cuda" else 1,  # CPU: keep up with speech; the final pass redoes it anyway
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 400},
            condition_on_previous_text=False,
            initial_prompt=prompt or None,
            temperature=[0.0, 0.2, 0.4],
        )
        out = [(clean(s.text.strip()), s.end) for s in segs]
        return [(t, e) for t, e in out if has_content(t)]


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
    return " ".join(t for t, _ in ready[: last + 1]), ready[last][1]


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
        self.committed = 0          # samples already committed (live mode)
        self.committed_text = ""

    def audio(self):
        if not self.chunks:
            return np.zeros(0, dtype=np.float32)
        pcm = np.frombuffer(b"".join(self.chunks), dtype=np.int16)
        return pcm.astype(np.float32) / 32768.0

    async def send(self, obj):
        await self.ws.send(json.dumps(obj))

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
                        None, self.engine.transcribe, audio, False, self.language, self.prompt)
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
            prompt = " ".join(p for p in (self.prompt, self.committed_text[-200:]) if p) or None
            try:
                async with self.gpu_lock:
                    if not self.active:
                        break
                    segs = await loop.run_in_executor(None, self.engine.segments, audio, self.language, prompt)
            except Exception as e:  # noqa: BLE001
                log.exception("live decode failed")
                await self.send({"type": "error", "code": "live_failed", "message": str(e)})
                continue
            if not self.active:
                break
            pick = choose_commit(segs, len(audio) / SAMPLE_RATE) if due_commit else None
            if pick:
                text, end = pick
                self.committed += int(end * SAMPLE_RATE)
                self.committed_text = (self.committed_text + " " + text).strip()
                await self.send({"type": "commit", "text": text})
                segs = [(t, e) for t, e in segs if e > end]
            await self.send({"type": "partial", "text": " ".join(t for t, _ in segs).strip()})

    def start(self, msg):
        self.chunks, self.samples, self.last_decoded = [], 0, 0
        self.language = msg.get("language") or None
        self.prompt = msg.get("prompt") or None
        self.live = bool(msg.get("live"))
        self.committed, self.committed_text = 0, ""
        self.active = True
        self.partial_task = asyncio.create_task(self._live_loop() if self.live else self._partial_loop())

    async def stop(self):
        self.active = False
        if self.partial_task:
            await self.partial_task
        t0 = time.time()
        audio = self.audio()
        if os.environ.get("DICTATION_DEBUG_DUMP"):  # diagnostics only, never set in normal use
            np.save(os.environ["DICTATION_DEBUG_DUMP"], audio)
        text = tail = ""
        loop = asyncio.get_running_loop()
        rest = audio[self.committed:]
        if self.live and self.committed:
            # Live mode: the committed pieces are already transcribed, so only the speech after the last one is
            # decoded. The final transcript is those pieces plus this tail; nothing is transcribed twice.
            if len(rest) >= SAMPLE_RATE * 0.3:
                prompt = " ".join(p for p in (self.prompt, self.committed_text[-200:]) if p) or None
                async with self.gpu_lock:
                    tail = await loop.run_in_executor(None, self.engine.transcribe, rest, True, self.language, prompt)
            text = (self.committed_text + " " + tail).strip()
        elif len(audio) >= SAMPLE_RATE * 0.3:
            async with self.gpu_lock:
                text = await loop.run_in_executor(
                    None, self.engine.transcribe, audio, True, self.language, self.prompt)
            tail = text if self.live else ""
        secs = len(audio) / SAMPLE_RATE
        self.chunks, self.samples, self.committed = [], 0, 0  # discard audio
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

    async with ws_serve(handler, "127.0.0.1", args.port, max_size=2**24):
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
