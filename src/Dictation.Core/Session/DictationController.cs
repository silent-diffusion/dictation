using System.Collections.ObjectModel;
using System.Diagnostics;
using Dictation.Core.Audio;
using Dictation.Core.Infrastructure;
using Dictation.Core.Insertion;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.Core.Session;

public enum DictationState { Idle, Starting, Recording, Transcribing, Processing, Confirming, Inserting }
public enum NoticeLevel { Info, Warning, Error }

/// <summary>One finished dictation. Raw is never overwritten by Processed.</summary>
public sealed class SessionRecord
{
    public DateTime Time { get; init; } = DateTime.Now;
    public string Raw { get; init; } = "";
    public string Processed { get; set; } = "";
    public string ProfileName { get; init; } = "";
    public string Target { get; init; } = "";
    public bool Inserted { get; set; }
    public string Summary => $"{Time:HH:mm:ss}  {ProfileName}  ·  {Target}";
}

/// <summary>What happened to a dictation that was inserted, for the overlay's receipt.</summary>
/// <param name="Elapsed">From the stop press until the text was in place.</param>
/// <param name="SafetyNet">The AI's edit was rejected by the profile's safety net, so the raw text was inserted.</param>
public sealed record InsertReceipt(string Raw, string Inserted, TimeSpan Elapsed, bool SafetyNet)
{
    public int Words => Inserted.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
    public bool Edited => Inserted != Raw;
}

/// <summary>
/// The dictation state machine: hotkey → mic → recognizer → (LLM) → insert.
/// Must be used from the UI thread (it awaits on the captured context so clipboard access stays on an STA thread).
/// UI subscribes to events; this class knows nothing about windows.
/// </summary>
public sealed class DictationController
{
    readonly IAudioCapture _mic;
    readonly ISpeechRecognizer _asr;
    readonly ITextProcessor _llm;
    readonly TextInserter _inserter;
    readonly SettingsService _settings;
    readonly ProfileService _profiles;
    readonly Stopwatch _recordClock = new();
    readonly Stopwatch _finishClock = new();
    CancellationTokenSource? _sessionCts;
    CancellationTokenSource? _maxDuration;
    InsertionTarget _target = InsertionTarget.Capture();
    string _pendingProcessed = "";
    string _pendingRaw = "";
    SessionRecord? _pendingRecord;
    bool _pendingSafetyNet;
    bool _micWarned;

    public DictationState State { get; private set; } = DictationState.Idle;
    public string LivePartial { get; private set; } = "";
    public string PreviewText => _pendingProcessed;
    /// <summary>The raw transcript of the dictation being cleaned up or previewed.</summary>
    public string PendingRaw => _pendingRaw;
    public ObservableCollection<SessionRecord> History { get; } = new();

    public event Action<DictationState>? StateChanged;
    public event Action<string>? PartialTranscript;
    public event Action<float>? AudioLevel;
    public event Action<string, NoticeLevel>? Notice;
    /// <summary>Raised after text was inserted, once the state is back to Idle.</summary>
    public event Action<InsertReceipt>? Inserted;

    public DictationController(IAudioCapture mic, ISpeechRecognizer asr, ITextProcessor llm, TextInserter inserter,
        SettingsService settings, ProfileService profiles)
    {
        _mic = mic; _asr = asr; _llm = llm; _inserter = inserter; _settings = settings; _profiles = profiles;
        _mic.DataAvailable += chunk => { if (State == DictationState.Recording) _asr.AcceptAudio(chunk); };
        _mic.LevelChanged += l => { if (State == DictationState.Recording) AudioLevel?.Invoke(l); };
        _mic.SilenceDetected += () =>
        {
            if (State == DictationState.Recording && !_micWarned)
            {
                _micWarned = true;
                Notice?.Invoke("The microphone is silent. Check Windows microphone privacy settings or pick another mic.", NoticeLevel.Warning);
            }
        };
        _asr.PartialTranscript += t =>
        {
            if (State != DictationState.Recording) return;
            LivePartial = t;
            PartialTranscript?.Invoke(t);
        };
    }

    public string TargetDescription => string.IsNullOrEmpty(_target.ProcessName) ? "" : _target.ProcessName;

    void SetState(DictationState s)
    {
        State = s;
        StateChanged?.Invoke(s);
    }

    /// <summary>The hotkey handler.</summary>
    public async void Toggle()
    {
        try
        {
            switch (State)
            {
                case DictationState.Idle: await StartAsync(); break;
                case DictationState.Recording: await StopAsync(); break;
                case DictationState.Confirming: await ConfirmInsertAsync(); break;
                // Starting / Transcribing / Processing / Inserting: ignore presses until done
            }
        }
        catch (Exception e)
        {
            Fail(e);
        }
    }

    void Fail(Exception e)
    {
        _mic.Stop();
        _asr.Cancel();
        _maxDuration?.Cancel();
        if (e is UserFacingException) Log.Warn("Dictation failed: " + e.Message);
        else Log.Error("Dictation failed", e);
        SetState(DictationState.Idle);
        Notice?.Invoke(e is UserFacingException ? e.Message : "Something went wrong during dictation. See data\\logs\\dictation.log.", NoticeLevel.Error);
    }

    async Task StartAsync()
    {
        _target = InsertionTarget.Capture(); // remember where the text should go
        LivePartial = "";
        _micWarned = false;
        _sessionCts = new CancellationTokenSource();
        SetState(DictationState.Starting);

        if (!_asr.IsReady)
        {
            // Not warmed up yet (or crashed): try to bring the engine up, but tell the user what is happening.
            Notice?.Invoke("Loading the speech model…", NoticeLevel.Info);
            await _asr.InitializeAsync(_sessionCts.Token);
        }

        _asr.Start();
        _mic.Start(_settings.Current.MicrophoneName);
        _recordClock.Restart();
        SetState(DictationState.Recording);

        _maxDuration = new CancellationTokenSource();
        var token = _maxDuration.Token;
        _ = Task.Delay(TimeSpan.FromSeconds(Math.Max(10, _settings.Current.MaxRecordingSeconds)), token).ContinueWith(t =>
        {
            if (t.IsCanceled || State != DictationState.Recording) return;
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(new Action(async () =>
            {
                Notice?.Invoke("Maximum recording length reached; finishing up.", NoticeLevel.Info);
                try { await StopAsync(); } catch (Exception e) { Fail(e); }
            }));
        }, TaskScheduler.Default);
    }

    async Task StopAsync()
    {
        _maxDuration?.Cancel();
        _mic.Stop();
        _recordClock.Stop();
        _finishClock.Restart();
        var ct = _sessionCts?.Token ?? CancellationToken.None;
        SetState(DictationState.Transcribing);

        var raw = OutputSanitizer.CollapseDots(await _asr.StopAsync(ct));
        if (!OutputSanitizer.HasContent(raw))
        {
            SetState(DictationState.Idle);
            Notice?.Invoke("I didn't catch anything. Try again.", NoticeLevel.Info);
            return;
        }

        var profile = _profiles.Active;
        var processed = raw;
        _pendingRaw = raw;
        _pendingSafetyNet = false;
        if (profile.AutoProcess)
        {
            SetState(DictationState.Processing);
            try
            {
                var result = await _llm.ProcessAsync(raw, profile, ct);
                processed = result.Text;
                // A safety-net rejection is reported on the receipt instead of as a separate notice.
                if (result.SafetyNet) _pendingSafetyNet = true;
                else if (result.Warning != null) Notice?.Invoke(result.Warning, NoticeLevel.Warning);
            }
            catch (UserFacingException e)
            {
                // Never lose the user's words because the AI failed.
                Log.Warn("LLM step failed: " + e.Message);
                Notice?.Invoke(e.Message + " Inserting your original words.", NoticeLevel.Warning);
            }
        }

        _pendingRaw = raw;
        _pendingProcessed = processed;
        _pendingRecord = new SessionRecord
        {
            Raw = raw, Processed = processed, ProfileName = profile.Name,
            Target = string.IsNullOrEmpty(_target.ProcessName) ? "unknown app" : _target.ProcessName,
        };

        if (profile.ShowPreview)
        {
            _finishClock.Stop(); // time spent reading the preview isn't processing time
            SetState(DictationState.Confirming);
            return;
        }
        await InsertPendingAsync(processed);
    }

    /// <summary>Hotkey pressed again while previewing: insert the processed text.</summary>
    async Task ConfirmInsertAsync() => await InsertPendingAsync(_pendingProcessed);

    /// <summary>Preview mode: insert the raw transcript instead of the processed one.</summary>
    public async void InsertRawInstead()
    {
        if (State != DictationState.Confirming) return;
        try { await InsertPendingAsync(_pendingRaw); } catch (Exception e) { Fail(e); }
    }

    async Task InsertPendingAsync(string text)
    {
        SetState(DictationState.Inserting);
        var rec = _pendingRecord;
        InsertReceipt? receipt = null;
        try
        {
            await _inserter.InsertAsync(text, _target, _sessionCts?.Token ?? CancellationToken.None);
            if (rec != null) { rec.Processed = text; rec.Inserted = true; }
            receipt = new InsertReceipt(_pendingRaw, text, _finishClock.Elapsed, _pendingSafetyNet);
        }
        catch (UserFacingException e)
        {
            // Last resort so the dictation isn't lost: leave it on the clipboard.
            try { System.Windows.Clipboard.SetText(text); } catch { }
            Notice?.Invoke(e.Message + " The text was copied to your clipboard.", NoticeLevel.Warning);
        }
        finally
        {
            if (rec != null && _settings.Current.KeepHistory)
            {
                History.Insert(0, rec);
                while (History.Count > 25) History.RemoveAt(History.Count - 1);
            }
            _pendingRecord = null;
            _pendingProcessed = _pendingRaw = "";
            _pendingSafetyNet = false;
            SetState(DictationState.Idle);
        }
        if (receipt != null) Inserted?.Invoke(receipt);
    }

    /// <summary>Esc / ✕: abandon whatever is in progress without inserting anything.</summary>
    public void Cancel()
    {
        switch (State)
        {
            case DictationState.Recording:
            case DictationState.Starting:
                _maxDuration?.Cancel();
                _mic.Stop();
                _asr.Cancel();
                break;
            case DictationState.Confirming:
                break;
            case DictationState.Transcribing:
            case DictationState.Processing:
                _sessionCts?.Cancel();
                break;
            default: return;
        }
        _pendingRecord = null;
        _pendingProcessed = _pendingRaw = "";
        SetState(DictationState.Idle);
    }

    /// <summary>Insert arbitrary text (e.g. the raw version from History) into the last target.</summary>
    public Task InsertIntoLastTargetAsync(string text) => _inserter.InsertAsync(text, _target);
}
