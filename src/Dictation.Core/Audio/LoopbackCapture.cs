using Dictation.Core.Infrastructure;
using NAudio.Wave;

namespace Dictation.Core.Audio;

/// <summary>
/// What the computer is playing (WASAPI loopback of the default output device): the other people on a video call, a
/// lecture video. Delivered as 16 kHz mono float samples, the speech engine's format. Windows sends nothing while
/// nothing plays, so whoever consumes it fills the gaps with silence (see <see cref="NotesMixer"/>).
/// </summary>
public sealed class LoopbackCapture : IDisposable
{
    WasapiLoopbackCapture? _capture;
    Resampler? _resampler;
    WaveFormat? _format;

    /// <summary>16 kHz mono samples, on a background thread.</summary>
    public event Action<float[]>? Samples;

    public void Start()
    {
        Stop();
        try
        {
            var capture = new WasapiLoopbackCapture();
            _format = capture.WaveFormat;
            _resampler = new Resampler(_format.SampleRate, MicCapture.SampleRate);
            capture.DataAvailable += OnData;
            capture.RecordingStopped += (_, e) => { if (e.Exception != null) Log.Error("Computer audio capture stopped", e.Exception); };
            capture.StartRecording();
            _capture = capture;
            Log.Info($"Computer audio: {_format.SampleRate} Hz, {_format.Channels} ch, {_format.BitsPerSample}-bit {_format.Encoding}");
        }
        catch (Exception e)
        {
            Stop();
            throw new UserFacingException("Couldn't listen to the computer's audio. Check that a sound output device is enabled.", e);
        }
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0 || _format == null || _resampler == null) return;
        var mono = Downmix(e.Buffer, e.BytesRecorded, _format);
        var output = _resampler.Process(mono);
        if (output.Length > 0) Samples?.Invoke(output);
    }

    /// <summary>Interleaved device samples (32-bit float, or 16/24/32-bit integer) to mono floats.</summary>
    internal static float[] Downmix(byte[] buffer, int bytes, WaveFormat f)
    {
        var channels = Math.Max(1, f.Channels);
        var bytesPerSample = f.BitsPerSample / 8;
        var frames = bytes / (bytesPerSample * channels);
        // Windows' shared mix format, which loopback delivers, is 32-bit float (often wrapped as "extensible").
        var isFloat = f.Encoding == WaveFormatEncoding.IeeeFloat ||
                      (f.Encoding == WaveFormatEncoding.Extensible && f.BitsPerSample == 32);
        var mono = new float[frames];
        for (var i = 0; i < frames; i++)
        {
            double sum = 0;
            for (var c = 0; c < channels; c++)
            {
                var at = (i * channels + c) * bytesPerSample;
                sum += bytesPerSample switch
                {
                    4 when isFloat => BitConverter.ToSingle(buffer, at),
                    4 => BitConverter.ToInt32(buffer, at) / 2147483648.0,
                    3 => ((buffer[at] << 8 | buffer[at + 1] << 16 | buffer[at + 2] << 24) >> 8) / 8388608.0,
                    2 => BitConverter.ToInt16(buffer, at) / 32768.0,
                    _ => 0,
                };
            }
            mono[i] = (float)(sum / channels);
        }
        return mono;
    }

    public void Stop()
    {
        var c = _capture;
        _capture = null;
        if (c == null) return;
        try { c.DataAvailable -= OnData; c.StopRecording(); } catch { }
        c.Dispose();
    }

    public void Dispose() => Stop();
}

/// <summary>
/// Streaming sample-rate converter for speech: each output sample averages the input around its position (a box filter
/// as wide as the rate ratio, which keeps what would fold into the speech band out of it), interpolated linearly.
/// </summary>
public sealed class Resampler
{
    readonly double _step; // input samples per output sample
    readonly int _half;
    readonly List<float> _buf = new();
    double _pos; // where the next output sample sits in _buf

    public Resampler(int inputRate, int outputRate)
    {
        _step = inputRate / (double)outputRate;
        _half = Math.Max(0, (int)Math.Floor(_step / 2));
    }

    public float[] Process(ReadOnlySpan<float> input)
    {
        foreach (var v in input) _buf.Add(v);
        var output = new List<float>((int)(input.Length / _step) + 2);
        while (_pos + _half + 1 < _buf.Count)
        {
            var i = (int)_pos;
            var frac = _pos - i;
            output.Add((float)(Average(i) * (1 - frac) + Average(i + 1) * frac));
            _pos += _step;
        }
        var drop = Math.Max(0, (int)_pos - _half - 1);
        if (drop > 0)
        {
            _buf.RemoveRange(0, Math.Min(drop, _buf.Count));
            _pos -= drop;
        }
        return output.ToArray();
    }

    double Average(int center)
    {
        double sum = 0;
        var n = 0;
        for (var k = center - _half; k <= center + _half; k++)
        {
            if (k < 0 || k >= _buf.Count) continue;
            sum += _buf[k];
            n++;
        }
        return n == 0 ? 0 : sum / n;
    }
}

/// <summary>
/// Mixes the microphone and the computer's audio into one 16 kHz mono 16-bit stream for Extended Notes. With the mic
/// in use, its clock paces the mix: every mic chunk takes as many computer samples as it has (silence when there are
/// none). Computer audio alone is paced by the caller's timer (<see cref="TakeComputer"/>). Thread-safe.
/// </summary>
public sealed class NotesMixer
{
    readonly object _lock = new();
    readonly Queue<float> _computer = new();
    /// <summary>At most this much computer audio waits for the mic (it is dropped beyond, oldest first).</summary>
    public const int MaxBacklog = MicCapture.SampleRate;

    public void AddComputer(float[] samples)
    {
        lock (_lock)
        {
            foreach (var s in samples) _computer.Enqueue(s);
            while (_computer.Count > MaxBacklog * 4) _computer.Dequeue();
        }
    }

    /// <summary>A mic chunk (16-bit PCM) mixed with the computer audio that arrived meanwhile.</summary>
    public byte[] MixWithMic(byte[] micPcm)
    {
        var n = micPcm.Length / 2;
        var output = new byte[n * 2];
        lock (_lock)
        {
            while (_computer.Count > MaxBacklog + n) _computer.Dequeue(); // clocks drift: never fall behind by more than a second
            for (var i = 0; i < n; i++)
            {
                var mic = (short)(micPcm[2 * i] | (micPcm[2 * i + 1] << 8)) / 32768f;
                var pc = _computer.Count > 0 ? _computer.Dequeue() : 0f;
                Write(output, i, mic + pc);
            }
        }
        return output;
    }

    /// <summary><paramref name="count"/> samples of computer audio alone (silence where none arrived).</summary>
    public byte[] TakeComputer(int count)
    {
        var output = new byte[count * 2];
        lock (_lock)
            for (var i = 0; i < count; i++) Write(output, i, _computer.Count > 0 ? _computer.Dequeue() : 0f);
        return output;
    }

    static void Write(byte[] pcm, int i, float v)
    {
        var s = (short)Math.Round(Math.Clamp(v, -1f, 1f) * 32767);
        pcm[2 * i] = (byte)s;
        pcm[2 * i + 1] = (byte)(s >> 8);
    }
}
