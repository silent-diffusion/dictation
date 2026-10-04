using Dictation.Core.Infrastructure;
using Dictation.Core.Speech;
using NAudio.Wave;

namespace Dictation.Core.Reading;

/// <summary>
/// Plays one text aloud. The text is split into sentences; each is synthesized just before it is needed (a few ahead),
/// so reading starts almost at once. Skipping works on the timeline of all sentences, using real durations where the
/// audio exists and estimates elsewhere. Changing speed re-synthesizes from the current sentence (Kokoro changes pace
/// without changing pitch). Public members are safe to call from the UI thread; audio runs on NAudio's thread.
/// It hands NAudio raw bytes (an <see cref="IWaveProvider"/>), not floats: NAudio's float view of its byte buffer is
/// a byte[] underneath, and Array.Copy/Array.Clear on it throw or clear a quarter of it, which silently stopped playback.
/// </summary>
public sealed class ReadAloudSession : IWaveProvider, IDisposable
{
    public const double MinSpeed = 0.5, MaxSpeed = 2.0, SpeedStep = 0.1;
    const int LookAhead = 2;

    readonly KokoroSpeech _tts;
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

    public ReadAloudSession(string text, KokoroSpeech tts, string voice, double speed)
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
                    if (!_ended)
                        for (var i = _index; i < Math.Min(_audio.Length, _index + 1 + LookAhead); i++)
                            if (_audio[i] == null) { next = i; break; }
                }
                if (next < 0) { await _wake.WaitAsync(ct); continue; }

                var samples = await _tts.SynthesizeAsync(_speakable[next], _voice, speed, ct);
                Provide(next, samples, generation, speed);
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

    /// <summary>Store a sentence's audio, unless the speed changed since it was requested.</summary>
    internal void Provide(int index, float[] samples, int generation, double speed)
    {
        lock (_lock)
        {
            if (generation != _generation) return; // the speed changed meanwhile
            _audio[index] = samples;
            if (speed > 0 && _speakable[index].Length > 20) // learn the voice's pace for better estimates
                _secondsPerChar = 0.7 * _secondsPerChar + 0.3 * (samples.Length / (double)KokoroSpeech.SampleRate * speed / _speakable[index].Length);
        }
    }

    internal int Generation { get { lock (_lock) return _generation; } }

    /// <summary>
    /// NAudio pulls audio here, in bytes of 32-bit float samples. Always fills the buffer (silence while paused or
    /// waiting) so the device keeps running.
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
                if (audio == null) break; // still being synthesized
                if (_resumeAt >= 0) { _pos = (int)(_resumeAt * audio.Length); _resumeAt = -1; }
                var n = Math.Min(wanted - written, audio.Length - _pos);
                if (n > 0)
                {
                    Buffer.BlockCopy(audio, _pos * 4, buffer, offset + written * 4, n * 4);
                    _pos += n;
                    written += n;
                }
                if (_pos >= audio.Length)
                {
                    _index++;
                    _pos = 0;
                    advanced = true;
                    if (_index >= _audio.Length) { _ended = true; _index = _audio.Length - 1; _pos = audio.Length; finished = true; }
                }
            }
        }
        if (written < wanted) Array.Clear(buffer, offset + written * 4, (wanted - written) * 4);
        if (advanced) _wake.Release();
        if (finished) ThreadPool.QueueUserWorkItem(_ => Finished?.Invoke());
        return count;
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _output?.Stop(); } catch { }
        _output?.Dispose();
        _output = null;
    }
}
