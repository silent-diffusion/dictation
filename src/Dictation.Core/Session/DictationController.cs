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
/// <param name="SafetyNet">The profile's safety net rejected the AI's edit of all or part of the text,
/// so those parts were inserted as spoken.</param>
/// <param name="Note">What the safety net did, for the receipt.</param>
public sealed record InsertReceipt(string Raw, string Inserted, TimeSpan Elapsed, bool SafetyNet, string? Note = null)
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
    Task<InsertionContext?> _context = Task.FromResult<InsertionContext?>(null);
    string _pendingProcessed = "";
    string _pendingRaw = "";
    SessionRecord? _pendingRecord;
    bool _pendingSafetyNet;
    string? _pendingNote;
    bool _micWarned;
    float _peakLevel; // loudest input level of the current recording, for SpeechGuard
    LiveInsertion? _live; // "type as you speak" for the current dictation, when enabled
    readonly List<string> _pieces = new(); // live mode: the pieces the recognizer committed, in order

    public DictationState State { get; private set; } = DictationState.Idle;
    public string LivePartial { get; private set; } = "";
    public string PreviewText => _pendingProcessed;
    /// <summary>The raw transcript of the dictation being cleaned up or previewed.</summary>
    public string PendingRaw => _pendingRaw;
    public ObservableCollection<SessionRecord> History { get; } = new();
    /// <summary>Text was typed while speaking, so the cleanup now is the final pass over it.</summary>
    public bool IsLive => _live?.HasTyped == true;

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
        _mic.LevelChanged += l =>
        {
            if (State != DictationState.Recording) return;
            if (l > _peakLevel) _peakLevel = l;
            AudioLevel?.Invoke(l);
        };
        _mic.SilenceDetected += () =>
        {
            if (State == DictationState.Recording && !_micWarned)
            {
                _micWarned = true;
                Notice?.Invoke("The microphone is silent. Check Windows microphone privacy settings or pick another mic.", NoticeLevel.Warning);
            }
        };
        // Live mode: finished pieces arrive on the recognizer's thread; type them from the UI thread, in order.
        _asr.Committed += t => System.Windows.Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
        {
            if (State is not (DictationState.Recording or DictationState.Transcribing)) return;
            _pieces.Add(t);
            _live?.Add(t);
        }));
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
        _live?.Stop(); // whatever was typed live stays
        _live = null;
        if (e is UserFacingException) Log.Warn("Dictation failed: " + e.Message);
        else Log.Error("Dictation failed", e);
        SetState(DictationState.Idle);
        Notice?.Invoke(e is UserFacingException ? e.Message : "Something went wrong during dictation. See data\\logs\\dictation.log.", NoticeLevel.Error);
    }

    async Task StartAsync()
    {
        _target = InsertionTarget.Capture(); // remember where the text should go
        // Read the text around the caret now, while the target app still has focus; used only when inserting.
        _context = _settings.Current.MatchSurroundingText
            ? InsertionContext.CaptureAsync(TimeSpan.FromMilliseconds(400))
            : Task.FromResult<InsertionContext?>(null);
        LivePartial = "";
        _pieces.Clear();
        _micWarned = false;
        _peakLevel = 0;
        _sessionCts = new CancellationTokenSource();
        SetState(DictationState.Starting);

        if (!_asr.IsReady)
        {
            // Not warmed up yet (or crashed): try to bring the engine up, but tell the user what is happening.
            Notice?.Invoke("Loading the speech model…", NoticeLevel.Info);
            await _asr.InitializeAsync(_sessionCts.Token);
        }

        var profile = _profiles.Active;
        // Live typing needs the text to go straight in, so it is off for profiles that preview before inserting.
        _live = _settings.Current.TypeWhileSpeaking && !profile.ShowPreview
            ? new LiveInsertion(_inserter, _llm, _target, profile, _context)
            : null;
        _asr.Start(live: _live != null);
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
        if (_live != null) await _live.DrainAsync(); // let pieces already on their way finish typing
        if (_live?.HasTyped != true && SpeechGuard.ShouldDiscard(raw, _recordClock.Elapsed, _peakLevel))
        {
            if (OutputSanitizer.HasContent(raw))
                Log.Info($"Discarded a likely phantom transcript ({raw.Length} chars, {_recordClock.Elapsed.TotalSeconds:0.0} s, peak {_peakLevel:0.00})");
            SetState(DictationState.Idle);
            Notice?.Invoke("I didn't catch anything. Try again.", NoticeLevel.Info);
            return;
        }

        raw = Stitch(raw);
        var profile = _profiles.Active;
        var processed = raw;
        _pendingRaw = raw;
        _pendingSafetyNet = false;
        _pendingNote = null;
        if (profile.AutoProcess)
        {
            SetState(DictationState.Processing); // with live typing, this is the final pass over the whole recording
            try
            {
                var result = await _llm.ProcessAsync(raw, profile, ct);
                processed = result.Text;
                // A safety-net rejection is reported on the receipt instead of as a separate notice.
                if (result.SafetyNet) { _pendingSafetyNet = true; _pendingNote = result.Warning; }
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

        if (profile.ShowPreview && !IsLive) // the profile may have been switched mid-dictation
        {
            _finishClock.Stop(); // time spent reading the preview isn't processing time
            SetState(DictationState.Confirming);
            return;
        }
        await InsertPendingAsync(processed);
    }

    /// <summary>
    /// The transcript with the seams between live pieces fixed (see <see cref="FragmentStitcher"/>). The recognizer's
    /// final text is the committed pieces plus the tail; if it isn't (live mode failed and the whole recording was
    /// decoded at once), there are no seams and the text is only tidied.
    /// </summary>
    string Stitch(string raw)
    {
        if (_pieces.Count == 0) return FragmentStitcher.Join(new[] { raw });
        var pieces = new List<string>(_pieces) { _asr.FinalTail };
        static string Words(string s) => string.Join(" ", s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var same = Words(OutputSanitizer.CollapseDots(string.Join(" ", pieces))) == Words(raw);
        return FragmentStitcher.Join(same ? pieces : new List<string> { raw });
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
            var ct = _sessionCts?.Token ?? CancellationToken.None;
            if (_live?.HasTyped == true)
            {
                // Replace what was typed while speaking with the final pass over the whole recording.
                var (inserted, note) = await _live.FinishAsync(text, _asr.FinalTail, ct);
                text = inserted;
                _pendingNote = note ?? _pendingNote;
            }
            else
            {
                // A rewrite was laid out on purpose: only fix the spacing around it.
                var profile = _profiles.Active;
                text = ContextFit.Fit(text, await _context, spacingOnly: profile.RewriteWhole && profile.AutoProcess && text != _pendingRaw);
                await _inserter.InsertAsync(text, _target, ct);
            }
            if (rec != null) { rec.Processed = text; rec.Inserted = true; }
            receipt = new InsertReceipt(_pendingRaw, text, _finishClock.Elapsed, _pendingSafetyNet, _pendingNote);
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
            _live = null;
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
        if (_live != null)
        {
            // Take back what was typed while speaking (only if it can be confirmed in place).
            var live = _live;
            _live = null;
            _ = live.RemoveTypedAsync();
        }
        _pendingRecord = null;
        _pendingProcessed = _pendingRaw = "";
        SetState(DictationState.Idle);
    }

    /// <summary>Insert arbitrary text (e.g. the raw version from History) into the last target.</summary>
    public Task InsertIntoLastTargetAsync(string text) => _inserter.InsertAsync(text, _target);
}
