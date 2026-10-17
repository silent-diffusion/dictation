using Dictation.Core.Infrastructure;
using NAudio.Wave;

namespace Dictation.Core.Notes;

/// <summary>A pause in a recording, in seconds.</summary>
public sealed class AudioPause
{
    public double Start { get; set; }
    public double End { get; set; }
}

/// <summary>A recording made ready to play (<see cref="NotesAudio.Prepare"/>): where the louder copy is, and its pauses.
/// Kept as JSON beside the copy, so a session opened again is ready at once.</summary>
public sealed class PreparedAudio
{
    public string Path { get; set; } = "";
    public double Seconds { get; set; }
    /// <summary>How much the level was raised.</summary>
    public double GainDb { get; set; }
    /// <summary>Pauses of <see cref="NotesAudio.MinSilence"/> or longer, in order.</summary>
    public List<AudioPause> Silences { get; set; } = new();

    /// <summary>The pause <paramref name="seconds"/> falls in, if any.</summary>
    public AudioPause? SilenceAt(double seconds)
    {
        foreach (var s in Silences)
        {
            if (s.Start > seconds) break;
            if (seconds < s.End) return s;
        }
        return null;
    }
}

/// <summary>
/// Gets a recording ready for playback. Microphone recordings are often very quiet, so the level is raised to bring the
/// speech near full scale (never lowered, and never by more than <see cref="MaxGainDb"/>), and the pauses are found so
/// playback can skip them. The result is a new 16-bit file; the recording itself is left as it is. Made once per
/// session and kept in the temp folder (<see cref="PrepareCached"/>).
/// </summary>
public static class NotesAudio
{
    /// <summary>Where the loud parts land: just under full scale.</summary>
    public const double TargetPeak = 0.89;
    public const double MaxGainDb = 40;
    /// <summary>A pause counts as a silence from this long.</summary>
    public const double MinSilence = 0.7;
    /// <summary>How much of a silence is kept when skipping it, so the speech doesn't run together.</summary>
    public const double KeepGap = 0.25;
    const double WindowSeconds = 0.05;

    /// <summary>The prepared copies, one per session, named by the session's id.</summary>
    public static string CacheDir => Path.Combine(Path.GetTempPath(), "oberton-notes");

    /// <summary>The prepared copy of a session's recording: made the first time, then found again (unless the recording
    /// is newer), so the session opens ready to play.</summary>
    public static PreparedAudio PrepareCached(string wavPath, string sessionId)
    {
        Directory.CreateDirectory(CacheDir);
        var copy = Path.Combine(CacheDir, sessionId + ".wav");
        var meta = Path.Combine(CacheDir, sessionId + ".json");
        if (File.Exists(copy) && File.Exists(meta) && File.GetLastWriteTimeUtc(copy) >= File.GetLastWriteTimeUtc(wavPath))
        {
            var cached = JsonStore.Load<PreparedAudio>(meta);
            if (cached != null && cached.Seconds > 0) { cached.Path = copy; return cached; }
        }
        var tmp = copy + ".tmp";
        var prepared = Prepare(wavPath, tmp);
        File.Move(tmp, copy, true);
        prepared.Path = copy;
        try { JsonStore.Save(meta, prepared); }
        catch (Exception e) { Log.Warn("Extended notes: couldn't keep the prepared recording's details: " + e.Message); }
        return prepared;
    }

    /// <summary>A session was deleted: its prepared copy goes too.</summary>
    public static void Forget(string sessionId)
    {
        foreach (var ext in new[] { ".wav", ".json", ".wav.tmp" })
        {
            try
            {
                var p = Path.Combine(CacheDir, sessionId + ext);
                if (File.Exists(p)) File.Delete(p);
            }
            catch { }
        }
    }

    public static PreparedAudio Prepare(string wavPath, string outPath)
    {
        var peaks = new List<float>();
        var levels = new List<float>(); // per window: the RMS in dB
        int rate, channels;
        double seconds;
        using (var reader = new WaveFileReader(wavPath))
        {
            rate = reader.WaveFormat.SampleRate;
            channels = reader.WaveFormat.Channels;
            seconds = reader.TotalTime.TotalSeconds;
            Scan(reader.ToSampleProvider(), (int)(rate * WindowSeconds) * channels, (peak, rms) => { peaks.Add(peak); levels.Add(Db(rms)); });
        }
        var gain = Gain(peaks);
        var silences = FindSilences(levels, WindowSeconds);
        using (var reader = new WaveFileReader(wavPath))
        using (var writer = new WaveFileWriter(outPath, new WaveFormat(rate, 16, channels)))
        {
            var sp = reader.ToSampleProvider();
            var buf = new float[rate * channels]; // a second
            var pcm = new byte[buf.Length * 2];
            int n;
            while ((n = sp.Read(buf, 0, buf.Length)) > 0)
            {
                for (var i = 0; i < n; i++)
                {
                    var v = (short)Math.Round(Math.Clamp(buf[i] * gain, -1f, 1f) * 32767);
                    pcm[2 * i] = (byte)v;
                    pcm[2 * i + 1] = (byte)(v >> 8);
                }
                writer.Write(pcm, 0, n * 2);
            }
        }
        var gainDb = 20 * Math.Log10(gain);
        Log.Info($"Extended notes: recording prepared, +{gainDb:0.0} dB, {silences.Count} pauses");
        return new PreparedAudio { Path = outPath, Seconds = seconds, GainDb = gainDb, Silences = silences };
    }

    static void Scan(ISampleProvider sp, int window, Action<float, float> onWindow)
    {
        window = Math.Max(1, window);
        var buf = new float[window];
        while (true)
        {
            var got = 0;
            while (got < window)
            {
                var n = sp.Read(buf, got, window - got);
                if (n <= 0) break;
                got += n;
            }
            if (got == 0) break;
            float peak = 0;
            double sum = 0;
            for (var i = 0; i < got; i++)
            {
                var a = Math.Abs(buf[i]);
                if (a > peak) peak = a;
                sum += buf[i] * buf[i];
            }
            onWindow(peak, (float)Math.Sqrt(sum / got));
            if (got < window) break;
        }
    }

    static float Db(double v) => (float)(20 * Math.Log10(Math.Max(v, 1e-6)));

    /// <summary>The gain that brings the loud windows to <see cref="TargetPeak"/>: the loudest half-percent of windows
    /// (a click, a bump) don't count, and the level is never lowered.</summary>
    public static float Gain(IReadOnlyList<float> windowPeaks)
    {
        if (windowPeaks.Count == 0) return 1;
        var sorted = windowPeaks.OrderBy(p => p).ToList();
        var loud = sorted[Math.Min(sorted.Count - 1, (int)(sorted.Count * 0.995))];
        if (loud <= 0.0005f) return 1; // silence: nothing to bring up
        return (float)Math.Clamp(TargetPeak / loud, 1, Math.Pow(10, MaxGainDb / 20));
    }

    /// <summary>The pauses: runs of windows well under the recording's own speech level and close to its noise floor.
    /// Relative, so a quiet recording and a loud one are treated alike.</summary>
    public static List<AudioPause> FindSilences(IReadOnlyList<float> levelsDb, double windowSeconds)
    {
        var result = new List<AudioPause>();
        if (levelsDb.Count < 4) return result;
        var sorted = levelsDb.OrderBy(l => l).ToList();
        var floor = sorted[(int)(sorted.Count * 0.2)];
        var speech = sorted[(int)(sorted.Count * 0.9)];
        var threshold = Math.Max(-65, Math.Min(floor + 8, speech - 20));
        var minWindows = (int)Math.Ceiling(MinSilence / windowSeconds);
        var start = -1;
        for (var i = 0; i <= levelsDb.Count; i++)
        {
            var quiet = i < levelsDb.Count && levelsDb[i] < threshold;
            if (quiet) { if (start < 0) start = i; continue; }
            if (start >= 0 && i - start >= minWindows) result.Add(new AudioPause { Start = start * windowSeconds, End = i * windowSeconds });
            start = -1;
        }
        return result;
    }
}
