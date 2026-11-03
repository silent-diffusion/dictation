"""Word timings in inference/asr_server.py: which words keep their timings once the filters have run.

Run from the repository root:  python -m unittest discover -s tests/inference
Needs no model: the engine's Whisper model is a stand-in. numpy is only needed for the session tests (skipped without
it); the word helpers don't use it.
"""
import asyncio
import importlib.util
import json
import os
import sys
import types
import unittest

try:
    import numpy  # noqa: F401
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False
    sys.modules["numpy"] = types.ModuleType("numpy")  # the module imports it; the helpers tested here don't use it

_path = os.path.join(os.path.dirname(__file__), "..", "..", "inference", "asr_server.py")
_spec = importlib.util.spec_from_file_location("asr_server", _path)
asr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(asr)


class Word:
    def __init__(self, word, start, end):
        self.word, self.start, self.end, self.probability = word, start, end, 0.9


class Segment:
    """Like a faster-whisper Segment: text, times, the doubt scores is_phantom reads, and its words."""

    def __init__(self, words, no_speech_prob=0.0, avg_logprob=-0.2, compression_ratio=1.2):
        self.words = [Word(*w) for w in words]
        self.text = "".join(w.word for w in self.words)
        self.start = self.words[0].start if self.words else 0.0
        self.end = self.words[-1].end if self.words else 0.0
        self.no_speech_prob, self.avg_logprob, self.compression_ratio = no_speech_prob, avg_logprob, compression_ratio


class Info:
    duration_after_vad = 5.0


class FakeModel:
    """Hands back the same segments whatever it is asked; remembers whether word timings were asked for."""

    def __init__(self, segments):
        self.segments, self.word_timestamps = segments, []

    def transcribe(self, audio, **kw):
        self.word_timestamps.append(kw.get("word_timestamps"))
        return iter(self.segments), Info()


def engine(segments):
    e = asr.FasterWhisperEngine("base.en", ".", "cpu", "int8")
    e.model = FakeModel(segments)
    return e


HELLO = Segment([(" Hello", 0.0, 0.4), (" there.", 0.4, 0.9)])
PHANTOM = Segment([(" Thank", 1.0, 1.2), (" you.", 1.2, 4.5)], no_speech_prob=0.7, avg_logprob=-0.9)
AGAIN = Segment([(" See", 5.0, 5.3), (" you", 5.3, 5.5), (" soon.", 5.5, 6.0)])


class WordHelpers(unittest.TestCase):
    def test_words_keep_their_text_and_times(self):
        self.assertEqual(asr.seg_words(HELLO), [["Hello", 0.0, 0.4], ["there.", 0.4, 0.9]])

    def test_punctuation_only_words_are_left_out(self):
        seg = Segment([(" Well", 0.0, 0.3), (" -", 0.3, 0.4), (" ...", 0.4, 0.6), (" yes.", 0.6, 0.9)])
        self.assertEqual([w[0] for w in asr.seg_words(seg)], ["Well", "yes."])

    def test_an_end_before_its_start_is_raised_to_it(self):
        seg = Segment([(" odd", 2.0, 1.5)])
        self.assertEqual(asr.seg_words(seg), [["odd", 2.0, 2.0]])

    def test_evened_audio_maps_back_to_the_recording(self):
        # Two regions cut out of the recording: 1 s at 2 s and 1 s at 10 s.
        regions = [(2 * asr.SAMPLE_RATE, 3 * asr.SAMPLE_RATE), (10 * asr.SAMPLE_RATE, 11 * asr.SAMPLE_RATE)]
        seg = Segment([(" one", 0.2, 0.5), (" two", 1.2, 1.6)])
        self.assertEqual(asr.seg_words(seg, regions), [["one", 2.2, 2.5], ["two", 10.2, 10.6]])

    def test_a_collapsed_repeat_keeps_the_first_ones_timings(self):
        words = [["Thank", 0, 1], ["you.", 1, 2], ["Thank", 2, 3], ["you.", 3, 4], ["Thank", 4, 5], ["you.", 5, 6],
                 ["Bye.", 6, 7]]
        text = asr.collapse_repeats("Thank you. Thank you. Thank you. Bye.")
        self.assertEqual(text, "Thank you. Bye.")
        self.assertEqual(asr.keep_words(words, text), [["Thank", 0, 1], ["you.", 1, 2], ["Bye.", 6, 7]])

    def test_words_the_text_lost_lose_their_timings(self):
        words = [["So", 0, 1], ["um", 1, 2], ["yes", 2, 3]]
        self.assertEqual(asr.keep_words(words, "So, yes!"), [["So", 0, 1], ["yes", 2, 3]])
        self.assertEqual(asr.keep_words(words, ""), [])

    def test_a_word_of_the_text_never_heard_skips_nothing(self):
        words = [["one", 0, 1], ["two", 1, 2]]
        self.assertEqual(asr.keep_words(words, "one extra two"), [["one", 0, 1], ["two", 1, 2]])

    def test_shifted_moves_pieces_into_the_session(self):
        self.assertEqual(asr.shifted([["a", 0.25, 0.5]], 10), [["a", 10.25, 10.5]])
        self.assertEqual(asr.shifted([["a", 0.25, 0.5]], 0), [["a", 0.25, 0.5]])

    def test_choose_commit_takes_phrases_with_their_words(self):
        segs = [("Hello there.", 0.9, [["Hello", 0, 0.4]]), ("And", 7.5, [])]
        self.assertEqual(asr.choose_commit(segs, 8.0), ("Hello there.", 0.9))


class EngineWords(unittest.TestCase):
    def test_phantom_phrases_drop_their_words(self):
        e = engine([HELLO, PHANTOM, AGAIN])
        text, words = e.transcribe_words(None, True, "en", None, drop_phantoms=True)
        self.assertEqual(text, "Hello there. See you soon.")
        self.assertEqual([w[0] for w in words], ["Hello", "there.", "See", "you", "soon."])
        self.assertEqual(e.model.word_timestamps, [True])

    def test_kept_when_phantoms_are_not_dropped(self):
        text, words = engine([HELLO, PHANTOM]).transcribe_words(None, True, "en", None)
        self.assertEqual(text, "Hello there. Thank you.")
        self.assertEqual(len(words), 4)

    def test_partials_never_ask_for_word_timings(self):
        e = engine([HELLO])
        self.assertEqual(e.transcribe(None, False, "en", None), "Hello there.")
        self.assertEqual(e.model.word_timestamps, [False])

    def test_live_segments_carry_words_only_when_asked(self):
        e = engine([HELLO, PHANTOM])
        self.assertEqual(e.segments(None, "en", None), [("Hello there.", 0.9, []), ("", 4.5, [])])
        with_words = e.segments(None, "en", None, words=True)
        self.assertEqual(with_words[0][2], [["Hello", 0.0, 0.4], ["there.", 0.4, 0.9]])
        self.assertEqual(with_words[1][2], [])  # a made-up phrase has no words
        self.assertEqual(e.model.word_timestamps, [False, True])

    def test_nothing_said_gives_no_words(self):
        dots = Segment([(" ...", 0.0, 1.0)])
        self.assertEqual(engine([dots]).transcribe_words([0.0] * asr.SAMPLE_RATE, True, "en", None), ("", []))


class FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, text):
        self.sent.append(json.loads(text))


class FakeLock:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False


@unittest.skipUnless(HAVE_NUMPY, "numpy isn't installed")
class SessionWords(unittest.TestCase):
    def run_stop(self, session):
        asyncio.run(session.stop())
        return session.ws.sent[-1]

    def test_final_words_of_a_whole_recording_drop_repeats(self):
        loop = Segment([(" Hi.", 0.0, 0.5), (" Hi.", 0.5, 1.0), (" Hi.", 1.0, 1.5), (" Bye.", 1.5, 2.0)])
        s = asr.Session(FakeWs(), engine([loop]), FakeLock())
        s.start({"type": "start", "drop_phantoms": True})
        s.active = False
        s.partial_task = None
        s.chunks, s.samples = [b"\0\0" * asr.SAMPLE_RATE], asr.SAMPLE_RATE
        final = self.run_stop(s)
        self.assertEqual(final["text"], "Hi. Bye.")
        self.assertEqual(final["words"], [["Hi.", 0.0, 0.5], ["Bye.", 1.5, 2.0]])
        self.assertEqual(final["tail_words"], [])

    def test_live_final_is_the_committed_words_plus_the_tail_moved_into_the_session(self):
        s = asr.Session(FakeWs(), engine([AGAIN]), FakeLock())
        s.start({"type": "start", "live": True})
        s.active = False
        s.partial_task = None
        # 20 s were committed and let go of ("Hello there." at 3 s); 2 s more are left to decode.
        s.committed_text, s.committed_words = "Hello there.", [["Hello", 3.0, 3.4], ["there.", 3.4, 3.9]]
        s.dropped = 20 * asr.SAMPLE_RATE
        s.chunks, s.samples = [b"\0\0" * (2 * asr.SAMPLE_RATE)], 2 * asr.SAMPLE_RATE
        final = self.run_stop(s)
        self.assertEqual(final["tail"], "See you soon.")
        self.assertEqual(final["tail_words"], [["See", 25.0, 25.3], ["you", 25.3, 25.5], ["soon.", 25.5, 26.0]])
        self.assertEqual([w[0] for w in final["words"]], ["Hello", "there.", "See", "you", "soon."])


if __name__ == "__main__":
    unittest.main()
