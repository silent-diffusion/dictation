"""Local text-to-speech server for Oberton's "Read aloud".

Runs the local voice models, each on ONNX Runtime (CPU), and answers one request at a time over a loopback WebSocket:

  * Kokoro v1.0 (82M parameters): the most natural voices. Voice ids like "af_heart".
  * Piper: small, fast voices, one model file per voice. Voice ids like "piper:en_US-lessac-medium".

    -> {"type": "speak", "id": 7, "text": "One sentence.", "voice": "af_heart", "speed": 1.0}
    <- {"type": "audio", "id": 7, "rate": 24000, "samples": 52800}
    <- <binary: float32 little-endian mono samples, always at 24 kHz>
    (or <- {"type": "error", "id": 7, "message": "..."})

The app sends one sentence per request, a few sentences ahead of playback, so reading starts almost immediately and
speed changes only re-synthesize what hasn't been played. Nothing here touches the network.
"""

import argparse
import asyncio
import json
import logging
import os
import sys
import unicodedata

import numpy as np

log = logging.getLogger("tts")

RATE = 24000  # every model's audio is delivered at this rate
PIPER = "piper:"


def lang_for(voice):
    """Kokoro voice names start with a language letter: a = American English, b = British English."""
    return "en-gb" if voice.startswith("b") else "en-us"


def resample(audio, rate):
    if rate == RATE or audio.size == 0:
        return audio
    n = int(round(audio.size * RATE / rate))
    return np.interp(np.linspace(0, audio.size - 1, n), np.arange(audio.size), audio)


def stretch(audio, factor):
    """Time-stretches by factor (2 = twice as fast) without changing the pitch: WSOLA, which overlap-adds
    40 ms windows and nudges each one to where it lines up best with the last, so voices don't warble."""
    n = 960
    hop = n // 2
    tol = hop // 2
    if abs(factor - 1) < 0.01 or audio.size < n * 2:
        return audio
    out_len = int(audio.size / factor)
    frames = out_len // hop + 1
    x = np.concatenate([np.zeros(tol), audio, np.zeros(n * 2 + int(hop * factor) + tol * 2)])
    win = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)
    y = np.zeros(frames * hop + n)
    weight = np.zeros(frames * hop + n)
    prev = tol
    for k in range(frames):
        nominal = int(k * hop * factor) + tol
        if k == 0:
            pos = nominal
        else:
            target = x[prev + hop:prev + hop + n]
            lo = nominal - tol
            corr = np.correlate(x[lo:nominal + tol + n], target, "valid")
            pos = lo + int(np.argmax(corr))
        y[k * hop:k * hop + n] += x[pos:pos + n] * win
        weight[k * hop:k * hop + n] += win
        prev = pos
    return (y / np.maximum(weight, 1e-3))[:out_len]


_espeak_ready = False


def phonemize(text, language):
    """espeak-ng IPA, the same phonemizer (bundled through espeakng-loader) that kokoro-onnx installs."""
    global _espeak_ready
    if not _espeak_ready:
        try:
            from kokoro_onnx.tokenizer import Tokenizer

            Tokenizer()  # points phonemizer at the bundled espeak-ng library and data
        except Exception:  # noqa: BLE001
            import espeakng_loader
            from phonemizer.backend.espeak.wrapper import EspeakWrapper

            EspeakWrapper.set_library(espeakng_loader.get_library_path())
            if hasattr(EspeakWrapper, "set_data_path"):
                EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
        _espeak_ready = True
    import phonemizer

    return phonemizer.phonemize(text, language, preserve_punctuation=True, with_stress=True)


class PiperVoice:
    """One Piper voice: <name>.onnx with its <name>.onnx.json config."""

    def __init__(self, path):
        import onnxruntime as ort

        with open(path + ".json", encoding="utf-8") as f:
            cfg = json.load(f)
        self.rate = cfg["audio"]["sample_rate"]
        self.ids = cfg["phoneme_id_map"]
        self.language = cfg.get("espeak", {}).get("voice", "en-us")
        inference = cfg.get("inference", {})
        self.noise = inference.get("noise_scale", 0.667)
        self.length = inference.get("length_scale", 1.0)
        self.noise_w = inference.get("noise_w", 0.8)
        self.session = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        self.inputs = {i.name for i in self.session.get_inputs()}

    def to_ids(self, phonemes):
        # As Piper does it: start, then each phoneme followed by padding, then end.
        ids = list(self.ids["^"])
        for p in unicodedata.normalize("NFD", phonemes):
            if p in self.ids:
                ids += self.ids[p] + self.ids["_"]
        return ids + self.ids["$"]

    def speak(self, text, speed):
        ids = self.to_ids(phonemize(text, self.language))
        feeds = {
            "input": np.array([ids], dtype=np.int64),
            "input_lengths": np.array([len(ids)], dtype=np.int64),
            "scales": np.array([self.noise, self.length / speed, self.noise_w], dtype=np.float32),
        }
        if "sid" in self.inputs:
            feeds["sid"] = np.array([0], dtype=np.int64)
        audio = self.session.run(None, feeds)[0].squeeze().astype(np.float32)
        return resample(audio, self.rate)


class Engine:
    def __init__(self, model_path, voices_path, piper_dir):
        self.kokoro = None
        self.voices = set()
        if model_path and voices_path and os.path.exists(model_path) and os.path.exists(voices_path):
            from kokoro_onnx import Kokoro

            self.kokoro = Kokoro(model_path, voices_path)
            self.voices = set(self.kokoro.get_voices())
        self.piper_dir = piper_dir
        self.piper = {}  # loaded Piper voices, by name

    def piper_voice(self, name):
        if name not in self.piper:
            path = os.path.join(self.piper_dir or "", os.path.basename(name) + ".onnx")
            if not os.path.exists(path):
                raise RuntimeError(f"the Piper voice {name} isn't downloaded")
            self.piper[name] = PiperVoice(path)
        return self.piper[name]

    def speak(self, text, voice, speed):
        speed = min(max(float(speed), 0.25), 4.0)
        # The voices pace themselves naturally between 0.5x and 2x; past that the rest is a pitch-safe stretch.
        native = min(max(speed, 0.5), 2.0)
        if voice.startswith(PIPER):
            audio = self.piper_voice(voice[len(PIPER):]).speak(text, native)
        else:
            if self.kokoro is None:
                raise RuntimeError("the Kokoro voices aren't downloaded")
            if voice not in self.voices:
                voice = "af_heart"
            audio, rate = self.kokoro.create(text, voice=voice, speed=native, lang=lang_for(voice))
            audio = resample(np.asarray(audio, dtype=np.float32), rate)
        audio = stretch(np.asarray(audio, dtype=np.float64), speed / native)
        return np.asarray(audio, dtype="<f4"), RATE


async def serve(port, engine):
    from websockets.asyncio.server import serve as ws_serve

    lock = asyncio.Lock()

    async def handler(ws):
        await ws.send(json.dumps({"type": "ready", "voices": sorted(engine.voices)}))
        loop = asyncio.get_running_loop()
        async for msg in ws:
            if isinstance(msg, bytes):
                continue
            data = json.loads(msg)
            if data.get("type") != "speak":
                continue
            rid = data.get("id")
            try:
                async with lock:
                    audio, rate = await loop.run_in_executor(
                        None, engine.speak, data.get("text", ""), data.get("voice", "af_heart"), data.get("speed", 1.0))
                await ws.send(json.dumps({"type": "audio", "id": rid, "rate": rate, "samples": int(audio.size)}))
                await ws.send(audio.tobytes())
            except Exception as e:  # noqa: BLE001
                log.exception("speak failed")
                await ws.send(json.dumps({"type": "error", "id": rid, "message": str(e)}))

    # No keepalive pings: the app is the only client, on loopback, and it does not read between requests, so
    # pings went unanswered and the idle connection was dropped after ~45 s.
    async with ws_serve(handler, "127.0.0.1", port, max_size=2**24, ping_interval=None):
        print(f"READY port={port}", flush=True)
        await asyncio.Future()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", help="kokoro .onnx model file (optional: Piper voices work without it)")
    p.add_argument("--voices", help="kokoro voices .bin file")
    p.add_argument("--piper-dir", help="folder with Piper voices (<name>.onnx and <name>.onnx.json)")
    p.add_argument("--port", type=int, default=8766)
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    try:
        engine = Engine(args.model, args.voices, args.piper_dir)
        if engine.kokoro is not None:
            engine.speak("Ready.", "af_heart", 1.0)  # warm-up, and a check that the model really works
    except Exception as e:  # noqa: BLE001
        print(f"ERROR model_load_failed: {e}", flush=True)
        sys.exit(2)
    log.info("Voice server ready (Kokoro: %s, Piper folder: %s)",
             "loaded" if engine.kokoro is not None else "not downloaded", args.piper_dir or "none")
    asyncio.run(serve(args.port, engine))


if __name__ == "__main__":
    main()
