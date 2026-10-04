"""Local text-to-speech server for Oberton's "Read aloud".

Runs Kokoro (82M parameters, ONNX, CPU) and answers one request at a time over a loopback WebSocket:

    -> {"type": "speak", "id": 7, "text": "One sentence.", "voice": "af_heart", "speed": 1.0}
    <- {"type": "audio", "id": 7, "rate": 24000, "samples": 52800}
    <- <binary: float32 little-endian mono samples>
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

import numpy as np

log = logging.getLogger("tts")


def lang_for(voice):
    """Kokoro voice names start with a language letter: a = American English, b = British English."""
    return "en-gb" if voice.startswith("b") else "en-us"


class Engine:
    def __init__(self, model_path, voices_path):
        from kokoro_onnx import Kokoro

        self.kokoro = Kokoro(model_path, voices_path)
        self.voices = set(self.kokoro.get_voices())

    def speak(self, text, voice, speed):
        if voice not in self.voices:
            voice = "af_heart"
        speed = min(max(float(speed), 0.5), 2.0)  # the range Kokoro sounds natural in
        audio, rate = self.kokoro.create(text, voice=voice, speed=speed, lang=lang_for(voice))
        return np.asarray(audio, dtype="<f4"), rate


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
    p.add_argument("--model", required=True, help="kokoro .onnx model file")
    p.add_argument("--voices", required=True, help="kokoro voices .bin file")
    p.add_argument("--port", type=int, default=8766)
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    try:
        engine = Engine(args.model, args.voices)
        engine.speak("Ready.", "af_heart", 1.0)  # warm-up, and a check that the model really works
    except Exception as e:  # noqa: BLE001
        print(f"ERROR model_load_failed: {e}", flush=True)
        sys.exit(2)
    log.info("Kokoro loaded from %s (%d voices)", os.path.basename(args.model), len(engine.voices))
    asyncio.run(serve(args.port, engine))


if __name__ == "__main__":
    main()
