using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Dictation.Core.Text;
using NAudio.Wave;

namespace Dictation.Core.Session;

/// <summary>
/// Runs a kept dictation again from its recording: transcribed afresh with today's speech settings (quiet speech
/// evened out, the vocabulary hint), then cleaned up again by the profile it was dictated with (or the active one, if
/// that profile is gone). The result replaces the entry's text; what it had before is kept as
/// <see cref="HistoryEntry.Earlier"/>, so it can be put back. Nothing is inserted, and the dashboard counts and
/// Analytics are left as they were (the dictation happened once).
/// </summary>
public sealed class HistoryRerun
{
    readonly SettingsService _settings;
    readonly ISpeechRecognizer _asr;
    readonly ITextProcessor _llm;
    readonly ProfileService _profiles;
    readonly HistoryStore _history;
    readonly Func<bool> _canSwapSpeechModel;

    /// <param name="canSwapSpeechModel">False while something else relies on the speech model loaded now (an Extended
    /// Notes session): the rerun then uses that model instead of the profile's.</param>
    public HistoryRerun(SettingsService settings, ISpeechRecognizer asr, ITextProcessor llm, ProfileService profiles,
        HistoryStore history, Func<bool> canSwapSpeechModel)
    {
        _settings = settings; _asr = asr; _llm = llm; _profiles = profiles; _history = history;
        _canSwapSpeechModel = canSwapSpeechModel;
    }

    /// <summary>Run <paramref name="entry"/> again; returns a sentence saying what was done. Use from the UI thread.</summary>
    public async Task<string> RunAsync(HistoryEntry entry, IProgress<string>? progress = null, CancellationToken ct = default)
    {
        if (!entry.HasAudio) throw new UserFacingException("The recording of this dictation isn't kept any more, so it can't be run again.");
        var profile = _profiles.Profiles.FirstOrDefault(p => string.Equals(p.Name, entry.Profile, StringComparison.OrdinalIgnoreCase));
        var profileNote = profile == null ? $" (the profile \"{entry.Profile}\" is gone, so {_profiles.Active.Name} was used)" : "";
        profile ??= _profiles.Active;
        var asr = _settings.Current.Asr;

        // 1. Speech: the profile's speech model, unless another one must stay loaded.
        var wanted = SpeechModels.For(profile, asr);
        if (!_asr.IsReady || !string.Equals(_asr.LoadedModel, wanted, StringComparison.OrdinalIgnoreCase) && _canSwapSpeechModel())
        {
            progress?.Report($"Loading {SpeechModels.NameOf(wanted)}…");
            await _asr.InitializeAsync(wanted, ct);
        }
        var speechModel = _asr.LoadedModel ?? wanted;
        progress?.Report($"Transcribing again with {SpeechModels.NameOf(speechModel)}…");
        string heard;
        var client = new SpeechSessionClient();
        try
        {
            await client.ConnectAsync(asr.Port, ct);
            client.Start(asr.Language, string.IsNullOrWhiteSpace(asr.VocabularyHint) ? null : asr.VocabularyHint, live: false,
                even: asr.EvenOutVolume);
            double seconds;
            using (var reader = new WaveFileReader(entry.AudioPath))
            {
                if (reader.WaveFormat.SampleRate != 16000 || reader.WaveFormat.Channels != 1 || reader.WaveFormat.BitsPerSample != 16)
                    throw new UserFacingException("This recording isn't in the format Oberton records in, so it can't be run again.");
                seconds = reader.TotalTime.TotalSeconds;
                var buffer = new byte[32000];
                int n;
                while ((n = reader.Read(buffer, 0, buffer.Length)) > 0)
                {
                    ct.ThrowIfCancellationRequested();
                    client.Send(buffer[..n]);
                }
            }
            heard = (await client.StopAsync(TimeSpan.FromSeconds(Math.Max(60, seconds * 4)))).Trim();
            if (!client.IsConnected && heard.Length == 0)
                throw new UserFacingException("The speech engine stopped while transcribing; nothing was changed.");
        }
        finally { await client.DisposeAsync(); }
        ct.ThrowIfCancellationRequested();
        if (!OutputSanitizer.HasContent(heard))
            throw new UserFacingException("Nothing was heard in the recording this time; the dictation was left as it was.");

        // 2. Cleanup by the profile, as a dictation does (but no surrounding text to fit: that moment is gone).
        var raw = FragmentStitcher.Tidy(heard);
        string final = raw;
        string? aiOutput = null, note = null;
        var safetyNet = false;
        if (profile.AutoProcess)
        {
            progress?.Report($"Cleaning up with {profile.Name}…");
            try
            {
                var result = await _llm.ProcessAsync(raw, profile, ct);
                final = result.Text;
                if (result.Modified) aiOutput = result.Text;
                if (result.SafetyNet) { safetyNet = true; note = result.Warning; }
            }
            catch (UserFacingException e) when (!ct.IsCancellationRequested)
            {
                Log.Warn("History: the AI step of running a dictation again failed: " + e.Message);
                note = e.Message + " The transcription was kept as heard.";
            }
        }
        ct.ThrowIfCancellationRequested();

        entry.Earlier = new HistoryVersion
        {
            Transcript = entry.Transcript, AiOutput = entry.AiOutput, Final = entry.Final, SafetyNet = entry.SafetyNet,
            Note = entry.Note, Profile = entry.Profile, WasInserted = entry.WasInserted,
        };
        entry.Transcript = raw;
        entry.AiOutput = aiOutput;
        entry.Final = final.Trim();
        entry.SafetyNet = safetyNet;
        entry.Profile = profile.Name;
        entry.WasInserted = false;
        entry.RunAgainAt = DateTime.Now;
        entry.Note = note;
        _history.Save(entry);
        Log.Info($"History: ran {entry.Time:yyyyMMdd-HHmmss} again ({SpeechModels.NameOf(speechModel)}, {profile.Name}): " +
                 $"{entry.Earlier.Transcript.Length}->{raw.Length} chars heard");
        return $"Run again with {SpeechModels.NameOf(speechModel)} and the {profile.Name} profile{profileNote}. Not inserted anywhere: copy it, or insert it below.";
    }

    /// <summary>Swap the entry's text with what it had before it was run again (so this undoes, and redoes, a rerun).</summary>
    public void SwapEarlier(HistoryEntry entry)
    {
        if (entry.Earlier is not { } e) return;
        var now = new HistoryVersion
        {
            Transcript = entry.Transcript, AiOutput = entry.AiOutput, Final = entry.Final, SafetyNet = entry.SafetyNet,
            Note = entry.Note, Profile = entry.Profile, WasInserted = entry.WasInserted,
        };
        entry.Transcript = e.Transcript;
        entry.AiOutput = e.AiOutput;
        entry.Final = e.Final;
        entry.SafetyNet = e.SafetyNet;
        entry.Note = e.Note;
        entry.Profile = e.Profile;
        entry.WasInserted = e.WasInserted;
        entry.Earlier = now;
        entry.ShowingEarlier = !entry.ShowingEarlier;
        _history.Save(entry);
    }
}
