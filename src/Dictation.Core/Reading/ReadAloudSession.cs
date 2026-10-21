using Dictation.Core.Infrastructure;
using Dictation.Core.Speech;
using NAudio.Wave;

namespace Dictation.Core.Reading;

/// <summary>
/// Plays one text aloud. The text is split into sentences, synthesized in order and played back to back; reading starts
/// as soon as the first is ready, and the voice keeps up to <see cref="BufferAheadSeconds"/> of audio ready ahead, so a
/// long sentence after short ones (or a busy moment on the PC) doesn't leave a gap. On a PC whose voice is slower than
/// real time, a wait lasts until enough is ready to read on without stopping again soon (see
/// <see cref="EnoughReadyLocked"/>): one longer pause rather than a gap at every sentence. Skipping works on the timeline of all sentences, using real durations where the
/// audio exists and estimates elsewhere. Changing speed re-synthesizes from the current sentence (Kokoro changes pace
/// without changing pitch). Public members are safe to call from the UI thread; audio runs on NAudio's thread.
/// It hands NAudio raw bytes (an <see cref="IWaveProvider"/>), not floats: NAudio's float view of its byte buffer is
/// a byte[] underneath, and Array.Copy/Array.Clear on it throw or clear a quarter of it, which silently stopped playback.
/// </summary>
public sealed class ReadAloudSession : IWaveProvider, IDisposable
{
    public const double MinSpeed = 0.25, MaxSpeed = 4.0, SpeedStep = 0.1;
    /// <summary>How much audio the voice keeps ready ahead of what is playing, in seconds.</summary>
    public const double BufferAheadSeconds = 30;
    /// <summary>The longest a wait on a slow PC lasts to build up audio before reading on, in seconds of audio.</summary>
    const double MaxCatchUpSeconds = 20;

    readonly ISpeechSynthesizer _tts;
    readonly string _voice;
    readonly float[]?[] _audio;
    readonly string[] _speakable;
    readonly object _lock = new();
    readonly SemaphoreSlim _wake = new(0);
    readonly CancellationTokenSource _cts = new();
    WaveOutEvent? _output;
    double _speed;
    int _generation;      // bumps when the speed changes; audio from an older generation is discarded
    int _index;           // sentence being played
    int _pos;             // sample position in it
    double _resumeAt = -1; // fraction of the current sentence to start from once its audio arrives
    bool _paused, _ended;
    double _secondsPerChar = ReadAloudText.DefaultSecondsPerChar; // at speed 1, learned from the real audio
    double _realTime = 1.5;      // seconds of audio the voice makes per second, learned as it goes (1.5 until known)
    bool _starved = true;        // the current sentence wasn't ready when it was needed (true at the start)
    long _starvedAt;             // when that wait began (Stopwatch ticks), to report waits
    int _waits;                  // waits after the first words, and how long they took in all
    double _waitedSeconds;
    bool _reported;

    public ReadAloudSession(string text, ISpeechSynthesizer tts, string voice, double speed)
    {
        Text = text;
        _tts = tts;
        _voice = voice;
        _speed = Math.Clamp(speed, MinSpeed, MaxSpeed);
        Sentences = ReadAloudText.Split(text);
        _audio = new float[]?[Sentences.Count];
        _speakable = Sentences.Select(s => ReadAloudText.Speakable(text, s)).ToArray();
    }

    public string Text { get; }
    public IReadOnlyList<TextSpan> Sentences { get; }
    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(KokoroSpeech.SampleRate, 1);

    /// <summary>Raised once, on a background thread, when the last sentence has played.</summary>
    public event Action? Finished;
    /// <summary>Raised on a background thread when the voice engine fails; reading stops.</summary>
    public event Action<string>? Failed;

    public double Speed { get { lock (_lock) return _speed; } }
    public bool IsPaused { get { lock (_lock) return _paused; } }
    /// <summary>How long the voice has spoken so far, in real time: the audio played (already at the reading's speed),
    /// without pauses, waits or the lead-in.</summary>
    public double SpokenSeconds { get { lock (_lock) return _spoken / (double)WaveFormat.SampleRate; } }
    long _spoken;
    public bool IsEnded { get { lock (_lock) return _ended; } }
    /// <summary>Playing, but the current sentence's audio isn't ready yet.</summary>
    public bool IsBuffering { get { lock (_lock) return !_ended && _index < _audio.Length && _audio[_index] == null; } }

    /// <summary>The sentence being read and how far into it (0..1).</summary>
    public (int Sentence, double Fraction) Position
    {
        get { lock (_lock) return (Math.Min(_index, Sentences.Count - 1), FractionLocked()); }
    }

    /// <summary>Time left at the current speed: real durations where synthesized, estimates elsewhere.</summary>
    public TimeSpan Remaining
    {
        get
        {
            lock (_lock)
            {
                if (_ended) return TimeSpan.Zero;
                var seconds = DurationLocked(_index) * (1 - FractionLocked());
                for (var i = _index + 1; i < _audio.Length; i++) seconds += DurationLocked(i);
                return TimeSpan.FromSeconds(seconds);
            }
        }
    }

    /// <summary>How much of the whole reading is done (0..1), by time.</summary>
    public double Progress
    {
        get
        {
            lock (_lock)
            {
                double before = 0, total = 0;
                for (var i = 0; i < _audio.Length; i++)
                {
                    var d = DurationLocked(i);
                    total += d;
                    if (i < _index) before += d;
                }
                if (_ended || total <= 0) return 1;
                return Math.Clamp((before + DurationLocked(_index) * FractionLocked()) / total, 0, 1);
            }
        }
    }

    public void Start()
    {
        if (Sentences.Count == 0) { _ended = true; Finished?.Invoke(); return; }
        _ = Task.Run(SynthesisLoopAsync);
        _output = new WaveOutEvent { DesiredLatency = 150 };
        _output.PlaybackStopped += (_, e) =>
        {
            // NAudio stops the device when Read throws or the device fails; never leave a frozen player behind.
            if (e.Exception == null) return;
            Log.Error("Read aloud playback stopped", e.Exception);
            lock (_lock)
            {
                if (_ended) return;
                _ended = true;
            }
            Failed?.Invoke("Playback failed: " + e.Exception.Message);
        };
        _output.Init(this);
        _output.Play();
    }

    public void TogglePause()
    {
        lock (_lock)
        {
            if (_ended) return;
            _paused = !_paused;
        }
    }

    /// <summary>Jump forwards or backwards in time, e.g. ±15 seconds.</summary>
    public void Skip(double seconds)
    {
        lock (_lock)
        {
            if (_ended && seconds > 0) return;
            _ended = false; // skipping back from the end resumes reading (the position stays at the very end)
            var now = 0.0;
            for (var i = 0; i < _index; i++) now += DurationLocked(i);
            now += DurationLocked(_index) * FractionLocked();
            var target = Math.Max(0, now + seconds);

            var start = 0.0;
            for (var i = 0; i < _audio.Length; i++)
            {
                var d = DurationLocked(i);
                if (target < start + d || i == _audio.Length - 1)
                {
                    SeekLocked(i, d > 0 ? Math.Clamp((target - start) / d, 0, 0.999) : 0);
                    break;
                }
                start += d;
            }
        }
        _wake.Release();
    }

    /// <summary>Jump to a spot in the text (a word clicked in the player): <paramref name="sentence"/>, a fraction of the
    /// way into it. Works forwards and backwards, and from the end (reading resumes).</summary>
    public void JumpTo(int sentence, double fraction)
    {
        lock (_lock)
        {
            if (sentence < 0 || sentence >= _audio.Length) return;
            _ended = false;
            SeekLocked(sentence, Math.Clamp(fraction, 0, 0.999));
            _leadIn = LeadInSamples; // a small runway, so the first word isn't clipped
        }
        _wake.Release();
    }

    /// <summary>Change the reading speed; the current sentence is re-read from the same point at the new pace.</summary>
    public void SetSpeed(double speed)
    {
        speed = Math.Round(Math.Clamp(speed, MinSpeed, MaxSpeed), 2);
        lock (_lock)
        {
            if (Math.Abs(speed - _speed) < 0.001 || _ended) return;
            var fraction = FractionLocked();
            _speed = speed;
            _generation++;
            Array.Clear(_audio);
            SeekLocked(_index, fraction);
        }
        _wake.Release();
    }

    void SeekLocked(int index, double fraction)
    {
        _index = index;
        _starved = true; // a jump (or a new speed) may have to wait for audio; that isn't the voice falling behind
        _starvedAt = 0;
        var audio = _audio[index];
        if (audio != null) { _pos = (int)(fraction * audio.Length); _resumeAt = -1; }
        else { _pos = 0; _resumeAt = fraction; }
    }

    double FractionLocked()
    {
        if (_index >= _audio.Length) return 1;
        var audio = _audio[_index];
        if (audio == null) return _resumeAt > 0 ? _resumeAt : 0;
        return audio.Length == 0 ? 1 : (double)_pos / audio.Length;
    }

    double DurationLocked(int i)
    {
        if (i < 0 || i >= _audio.Length) return 0;
        var audio = _audio[i];
        return audio != null
            ? audio.Length / (double)KokoroSpeech.SampleRate
            : _speakable[i].Length * _secondsPerChar / _speed;
    }

    /// <summary>Keeps the current sentence and the next few synthesized, in order of need.</summary>
    async Task SynthesisLoopAsync()
    {
        var ct = _cts.Token;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                int next = -1, generation;
                double speed;
                lock (_lock)
                {
                    generation = _generation;
                    speed = _speed;
                    if (!_ended) next = NextToSynthesizeLocked();
                }
                if (next < 0) { await _wake.WaitAsync(ct); continue; }

                var clock = System.Diagnostics.Stopwatch.StartNew();
                var samples = await _tts.SynthesizeAsync(_speakable[next], _voice, speed, ct);
                Provide(next, samples, generation, speed, clock.Elapsed.TotalSeconds);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Log.Warn("Read aloud stopped: " + e.Message);
            lock (_lock) _ended = true;
            Failed?.Invoke(e is UserFacingException ? e.Message : "The voice engine stopped unexpectedly.");
        }
    }

    /// <summary>The first sentence from the current one on that has no audio yet, while less than
    /// <see cref="BufferAheadSeconds"/> is ready ahead; -1 when there is enough (or nothing left).</summary>
    internal int NextToSynthesizeLocked()
    {
        var ahead = 0.0;
        for (var i = _index; i < _audio.Length; i++)
        {
            if (_audio[i] == null) return i == _index || ahead < BufferAheadSeconds ? i : -1;
            ahead += i == _index ? DurationLocked(i) * (1 - FractionLocked()) : DurationLocked(i);
            if (ahead >= BufferAheadSeconds) return -1;
        }
        return -1;
    }

    /// <summary>After a wait: whether to read on now. Always, when the voice is faster than real time or everything left
    /// is ready. Otherwise only once the audio ready ahead will last while the rest is made (the remaining time times
    /// the share the voice can't keep up with, at most <see cref="MaxCatchUpSeconds"/>), so a slow PC pauses once and
    /// reads on, instead of stopping at every sentence.</summary>
    internal bool EnoughReadyLocked()
    {
        if (_realTime >= 1) return true;
        var ready = 0.0;
        var i = _index;
        for (; i < _audio.Length && _audio[i] != null; i++)
            ready += i == _index ? DurationLocked(i) * (1 - FractionLocked()) : DurationLocked(i);
        if (i >= _audio.Length) return true;
        var rest = ready;
        for (var j = i; j < _audio.Length; j++) rest += DurationLocked(j);
        return ready >= Math.Min(rest * (1 - _realTime), MaxCatchUpSeconds);
    }

    /// <summary>Store a sentence's audio, unless the speed changed since it was requested. <paramref name="seconds"/>:
    /// how long making it took (0 when not measured), to learn how fast the voice is on this PC.</summary>
    internal void Provide(int index, float[] samples, int generation, double speed, double seconds = 0)
    {
        lock (_lock)
        {
            if (generation != _generation) return; // the speed changed meanwhile
            _audio[index] = samples;
            if (seconds > 0.05 && samples.Length > 0)
                _realTime = 0.7 * _realTime + 0.3 * (samples.Length / (double)KokoroSpeech.SampleRate / seconds);
            if (speed > 0 && _speakable[index].Length > 20) // learn the voice's pace for better estimates
                _secondsPerChar = 0.7 * _secondsPerChar + 0.3 * (samples.Length / (double)KokoroSpeech.SampleRate * speed / _speakable[index].Length);
        }
    }

    internal int Generation { get { lock (_lock) return _generation; } }

    /// <summary>A quarter-second runway of near-silence before speech starts, or resumes after a wait.</summary>
    internal const int LeadInSamples = KokoroSpeech.SampleRate / 4;
    /// <summary>The level of the "silence" sent instead of zeros: about −80 dB, inaudible.</summary>
    const float DitherLevel = 1e-4f;
    int _leadIn = LeadInSamples; // samples of runway still to play before the current audio
    uint _noise = 0x9E3779B9;    // a tiny, cheap noise generator for the runway and the waits

    /// <summary>
    /// NAudio pulls audio here, in bytes of 32-bit float samples. Always fills the buffer so the device keeps running.
    /// Pauses and waits are filled with inaudible noise rather than exact zeros: many sound drivers and Bluetooth
    /// headsets power down on true digital silence and fade back in when sound returns, which swallowed the first word
    /// of a reading, or of a sentence that had to be waited for (common at high speed). For the same reason speech that
    /// starts after a wait gets a short runway first, so any fade-in happens before the words.
    /// </summary>
    public int Read(byte[] buffer, int offset, int count)
    {
        count -= count % 4; // whole samples only
        var wanted = count / 4;
        var written = 0; // in samples
        var finished = false;
        var advanced = false;
        lock (_lock)
        {
            while (written < wanted && !_paused && !_ended)
            {
                var audio = _audio[_index];
                if (audio == null || _starved && !EnoughReadyLocked())
                {
                    // Still being synthesized (or, on a slow PC, not enough ready yet): wait, with a runway once it is.
                    if (!_starved) { _starved = true; _starvedAt = System.Diagnostics.Stopwatch.GetTimestamp(); }
                    _leadIn = LeadInSamples;
                    break;
                }
                if (_starved)
                {
                    _starved = false;
                    if (_spoken > 0 && _starvedAt != 0)
                    {
                        _waits++;
                        _waitedSeconds += System.Diagnostics.Stopwatch.GetElapsedTime(_starvedAt).TotalSeconds;
                    }
                }
                if (_leadIn > 0)
                {
                    var r = Math.Min(_leadIn, wanted - written);
                    Fill(buffer, offset + written * 4, r);
                    _leadIn -= r;
                    written += r;
                    continue;
                }
                if (_resumeAt >= 0) { _pos = (int)(_resumeAt * audio.Length); _resumeAt = -1; }
                var n = Math.Min(wanted - written, audio.Length - _pos);
                if (n > 0)
                {
                    Buffer.BlockCopy(audio, _pos * 4, buffer, offset + written * 4, n * 4);
                    _pos += n;
                    written += n;
                    _spoken += n;
                }
                if (_pos >= audio.Length)
                {
                    _index++;
                    _pos = 0;
                    advanced = true;
                    if (_index >= _audio.Length) { _ended = true; _index = _audio.Length - 1; _pos = audio.Length; finished = true; }
                }
            }
            if (_paused) _leadIn = LeadInSamples; // resuming from a pause gets the runway too
            if (written < wanted) Fill(buffer, offset + written * 4, wanted - written);
        }
        if (advanced) _wake.Release();
        if (finished) ThreadPool.QueueUserWorkItem(_ => Finished?.Invoke());
        return count;
    }

    /// <summary>Write <paramref name="samples"/> of inaudible noise (never exact zeros).</summary>
    void Fill(byte[] buffer, int byteOffset, int samples)
    {
        for (var i = 0; i < samples; i++)
        {
            _noise ^= _noise << 13; _noise ^= _noise >> 17; _noise ^= _noise << 5; // xorshift
            var v = ((_noise & 0xFFFF) / 32768f - 1f) * DitherLevel;
            BitConverter.TryWriteBytes(buffer.AsSpan(byteOffset + i * 4, 4), v);
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (!_reported && _spoken > 0)
                Log.Info($"Read aloud: {Sentences.Count} sentence(s), the voice at {_realTime:0.0}x real time; " +
                         (_waits == 0 ? "no waits" : $"waited {_waits} time(s), {_waitedSeconds:0.0} s in all") + " after the first words");
            _reported = true;
        }
        _cts.Cancel();
        try { _output?.Stop(); } catch { }
        _output?.Dispose();
        _output = null;
    }
}
