using Dictation.Core.Infrastructure;
using NAudio.Wave;

namespace Dictation.Core.Audio;

public interface IAudioCapture : IDisposable
{
    /// <summary>16 kHz mono 16-bit PCM chunks (~50 ms each). Raised on a background thread.</summary>
    event Action<byte[]>? DataAvailable;
    /// <summary>0..1 loudness, ~20 times per second.</summary>
    event Action<float>? LevelChanged;
    /// <summary>Raised if the stream is silent (all zeros) - usually Windows blocking mic access.</summary>
    event Action? SilenceDetected;
    void Start(string? deviceName);
    void Stop();
    IReadOnlyList<string> ListDevices();
}

public sealed class MicCapture : IAudioCapture
{
    public const int SampleRate = 16000;
    WaveInEvent? _wave;
    int _silentBuffers;
    bool _sawSignal;

    public event Action<byte[]>? DataAvailable;
    public event Action<float>? LevelChanged;
    public event Action? SilenceDetected;

    public IReadOnlyList<string> ListDevices()
    {
        var list = new List<string>();
        for (var i = 0; i < WaveInEvent.DeviceCount; i++) list.Add(WaveInEvent.GetCapabilities(i).ProductName);
        return list;
    }

    public void Start(string? deviceName)
    {
        Stop();
        if (WaveInEvent.DeviceCount == 0)
            throw new UserFacingException("No microphone was found. Plug one in or enable it in Windows Sound settings.");

        var device = -1; // default device
        if (!string.IsNullOrWhiteSpace(deviceName))
        {
            for (var i = 0; i < WaveInEvent.DeviceCount; i++)
                if (WaveInEvent.GetCapabilities(i).ProductName.Equals(deviceName, StringComparison.OrdinalIgnoreCase)) { device = i; break; }
            if (device == -1) Log.Warn($"Microphone '{deviceName}' not found; using the default device.");
        }

        _silentBuffers = 0;
        _sawSignal = false;
        try
        {
            _wave = new WaveInEvent
            {
                DeviceNumber = device,
                WaveFormat = new WaveFormat(SampleRate, 16, 1),
                BufferMilliseconds = 50,
                NumberOfBuffers = 4,
            };
            _wave.DataAvailable += OnData;
            _wave.RecordingStopped += (_, e) => { if (e.Exception != null) Log.Error("Recording stopped with error", e.Exception); };
            _wave.StartRecording();
        }
        catch (Exception e)
        {
            _wave?.Dispose();
            _wave = null;
            throw new UserFacingException(
                "Could not open the microphone. Check that it is connected and that Windows allows desktop apps to use it " +
                "(Settings > Privacy & security > Microphone).", e);
        }
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;
        var chunk = new byte[e.BytesRecorded];
        Buffer.BlockCopy(e.Buffer, 0, chunk, 0, e.BytesRecorded);

        long sum = 0;
        var peak = 0;
        for (var i = 0; i + 1 < chunk.Length; i += 2)
        {
            int s = (short)(chunk[i] | (chunk[i + 1] << 8));
            sum += (long)s * s;
            peak = Math.Max(peak, Math.Abs(s));
        }
        var rms = Math.Sqrt(sum / (chunk.Length / 2.0)) / 32768.0;
        LevelChanged?.Invoke((float)Math.Min(1.0, Math.Sqrt(rms) * 1.8)); // sqrt curve: quiet speech still shows

        if (peak > 0) _sawSignal = true;
        else if (!_sawSignal && ++_silentBuffers == 40) SilenceDetected?.Invoke(); // 2 s of pure zeros

        DataAvailable?.Invoke(chunk);
    }

    public void Stop()
    {
        var w = _wave;
        _wave = null;
        if (w == null) return;
        try { w.DataAvailable -= OnData; w.StopRecording(); } catch { }
        w.Dispose();
    }

    public void Dispose() => Stop();
}
