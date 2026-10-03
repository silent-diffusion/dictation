using NAudio.Wave;

namespace Dictation.Core.Audio;

/// <summary>
/// Test/diagnostic audio source: "speaks" a 16 kHz mono 16-bit WAV file in real time instead of using the microphone.
/// Enabled only by setting the environment variable DICTATION_FAKE_AUDIO to a file path.
/// </summary>
public sealed class FileAudioCapture : IAudioCapture
{
    readonly string _path;
    CancellationTokenSource? _cts;

    public FileAudioCapture(string path) => _path = path;

    public event Action<byte[]>? DataAvailable;
    public event Action<float>? LevelChanged;
    public event Action? SilenceDetected { add { } remove { } }

    public IReadOnlyList<string> ListDevices() => new[] { "(test file)" };

    public void Start(string? deviceName)
    {
        Stop();
        var cts = _cts = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            using var reader = new WaveFileReader(_path);
            var buf = new byte[1600]; // 50 ms @ 16 kHz 16-bit mono
            int n;
            while (!cts.IsCancellationRequested && (n = reader.Read(buf, 0, buf.Length)) > 0)
            {
                var chunk = new byte[n];
                Buffer.BlockCopy(buf, 0, chunk, 0, n);
                LevelChanged?.Invoke(0.4f);
                DataAvailable?.Invoke(chunk);
                await Task.Delay(50);
            }
        });
    }

    public void Stop() { _cts?.Cancel(); _cts = null; }
    public void Dispose() => Stop();
}
