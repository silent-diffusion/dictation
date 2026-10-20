using System.Diagnostics;
using Dictation.Core.Audio;
using Dictation.Core.Infrastructure;
using Dictation.Core.Insertion;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.Core.Session;

/// <summary><see cref="Placing"/>: the text is ready, but nothing to type into had the cursor when the dictation
/// started; it waits for the user to click into a text field (or copy it).</summary>
public enum DictationState { Idle, Starting, Recording, Transcribing, Processing, Confirming, Inserting, Placing }
public enum NoticeLevel { Info, Warning, Error }

/// <summary>What happened to a dictation that was inserted, for the overlay's receipt.</summary>
/// <param name="Elapsed">From the stop press until the text was in place.</param>
/// <param name="SafetyNet">The profile's safety net rejected the AI's edit of all or part of the text,
/// so those parts were inserted as spoken.</param>
/// <param name="Note">What the safety net did, for the receipt.</param>
/// <param name="AiEdit">What the AI made of <paramref name="Raw"/>, before it was fitted into the text around the cursor;
/// null when no AI was used (a profile without AI, the AI failed, or the original words were chosen).</param>
/// <param name="Context">The text around the cursor when the dictation started, if it could be read.</param>
public sealed record InsertReceipt(string Raw, string Inserted, TimeSpan Elapsed, bool SafetyNet, string? Note = null,
    string? AiEdit = null, InsertionContext? Context = null)
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
    readonly HistoryStore _history;
    readonly UsageStore? _usage; // counts for the dashboard, kept even when History is off
    readonly WordTally? _tally;  // word and phrase counts for Analytics
    readonly Stopwatch _recordClock = new();
    readonly Stopwatch _finishClock = new();
    CancellationTokenSource? _sessionCts;
    CancellationTokenSource? _maxDuration;
    InsertionTarget _target = InsertionTarget.Capture();
    Task<InsertionContext?> _context = Task.FromResult<InsertionContext?>(null);
    string _pendingProcessed = "";
    string _pendingRaw = "";
    string _pendingProfile = "";
    bool _pendingSafetyNet;
    string? _pendingNote;
    string? _pendingAiEdit; // the AI's output for the pending dictation, if the AI ran
    Task<PasteSpot> _spot = Task.FromResult(PasteSpot.Unknown); // where the cursor was when the dictation started
    CancellationTokenSource? _placeCts; // while Placing: waiting for the user to click somewhere to type
    string _placingText = "";
    bool _placed; // the text went where the user clicked, not where the dictation started
    // For the dashboard's turnaround: which models this dictation used, and whether they were loaded when it started.
    string _speechModelUsed = "", _aiModelUsed = "";
    bool _speechWarm;
    Task<bool> _aiWarm = Task.FromResult(true);
    bool _micWarned;
    float _peakLevel; // loudest input level of the current recording, for SpeechGuard
    LiveInsertion? _live; // "type as you speak" for the current dictation, when enabled
    readonly List<string> _pieces = new(); // live mode: the pieces the recognizer committed, in order
    string _partial = ""; // the recognizer's running guess at the speech not committed yet

    // Audio: everything recorded (for History), and what arrived before the speech engine was ready.
    readonly object _audioLock = new();
    MemoryStream _recording = new();
    readonly List<byte[]> _waiting = new();
    bool _streaming; // the recognizer has the session; chunks go straight to it
    Task _engine = Task.CompletedTask; // loads the engine if needed, then starts the recognizer's session

    public DictationState State { get; private set; } = DictationState.Idle;
    public string PreviewText => _pendingProcessed;
    /// <summary>The raw transcript of the dictation being cleaned up or previewed.</summary>
    public string PendingRaw => _pendingRaw;
    /// <summary>Text was typed while speaking, so the cleanup now is the final pass over it.</summary>
    public bool IsLive => _live?.HasTyped == true;
    /// <summary>When a dictation last started or finished; for unloading idle models.</summary>
    public DateTime LastActivity { get; private set; } = DateTime.Now;
    /// <summary>The text around the cursor for the current dictation (read when it started), once known; shown next to
    /// the AI edit so the edit can be judged in place.</summary>
    public InsertionContext? Context { get; private set; }

    public event Action<DictationState>? StateChanged;
    /// <summary>The transcript so far, while recording (UI thread). Empty at the start of a dictation.</summary>
    public event Action<string>? LiveTranscript;
    /// <summary>True while a dictation waits for the speech model to load (recording goes on meanwhile).</summary>
    public event Action<bool>? EngineLoading;
    public event Action<float>? AudioLevel;
    public event Action<string, NoticeLevel>? Notice;
    /// <summary>Raised after text was inserted, once the state is back to Idle.</summary>
    public event Action<InsertReceipt>? Inserted;

    public DictationController(IAudioCapture mic, ISpeechRecognizer asr, ITextProcessor llm, TextInserter inserter,
        SettingsService settings, ProfileService profiles, HistoryStore history, UsageStore? usage = null, WordTally? tally = null)
    {
        _mic = mic; _asr = asr; _llm = llm; _inserter = inserter; _settings = settings; _profiles = profiles; _history = history; _usage = usage;
        _tally = tally;
        _mic.DataAvailable += OnAudio;
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
        _asr.Committed += t => OnUi(() =>
        {
            if (State is not (DictationState.Recording or DictationState.Transcribing)) return;
            _pieces.Add(t);
            _partial = "";
            _live?.Add(t);
            RaiseTranscript();
        });
        _asr.PartialTranscript += t => OnUi(() =>
        {
            if (State != DictationState.Recording) return;
            _partial = t;
            RaiseTranscript();
            _live?.SetPartial(t); // a profile without AI types it right away, so the app shows what the overlay shows
        });
    }

    static void OnUi(Action a) => System.Windows.Application.Current?.Dispatcher.BeginInvoke(a);

    /// <summary>Microphone audio (background thread): kept for History, and passed to the recognizer once it is ready.</summary>
    void OnAudio(byte[] chunk)
    {
        if (State != DictationState.Recording) return;
        lock (_audioLock)
        {
            _recording.Write(chunk, 0, chunk.Length);
            if (_streaming) _asr.AcceptAudio(chunk);
            else _waiting.Add(chunk);
        }
    }

    void RaiseTranscript()
    {
        var parts = new List<string>(_pieces);
        if (_partial.Length > 0) parts.Add(_partial);
        LiveTranscript?.Invoke(parts.Count == 0 ? "" : FragmentStitcher.Join(parts));
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
                case DictationState.Recording: await StopCancellableAsync(); break;
                case DictationState.Confirming: await ConfirmInsertAsync(); break;
                case DictationState.Placing: CopyPlacingToClipboard(); break;
                // Starting / Transcribing / Processing / Inserting: ignore presses until done
            }
        }
        catch (Exception e)
        {
            Fail(e);
        }
    }

    /// <summary>
    /// A dictation cancelled (Esc / ✕) while it was finishing still completes its awaits afterwards, often with an error
    /// (the model it waited for loaded, a request was cancelled). That is not a failure, and it must not touch a newer
    /// dictation, so it ends quietly.
    /// </summary>
    async Task StopCancellableAsync()
    {
        var session = _sessionCts;
        try { await StopAsync(); }
        catch (Exception e) when (session is { IsCancellationRequested: true })
        {
            Log.Info("A cancelled dictation ended: " + e.GetType().Name);
        }
    }

    void Fail(Exception e)
    {
        _mic.Stop();
        _asr.Cancel();
        _maxDuration?.Cancel();
        _sessionCts?.Cancel();
        _live?.Stop(); // whatever was typed live stays
        _live = null;
        LastActivity = DateTime.Now;
        if (e is UserFacingException) Log.Warn("Dictation failed: " + e.Message);
        else Log.Error("Dictation failed", e);
        SetState(DictationState.Idle);
        Notice?.Invoke(e is UserFacingException ? e.Message : "Something went wrong during dictation. See data\\logs\\dictation.log.", NoticeLevel.Error);
    }

    async Task StartAsync()
    {
        _target = InsertionTarget.Capture(); // remember where the text should go
        // ...down to the caret position, while the target app still has focus (or that there is nowhere to type).
        _spot = PasteSpot.CaptureAsync(_target, TimeSpan.FromMilliseconds(400));
        _placed = false;
        // Read the text around the caret now, while the target app still has focus; used only when inserting.
        _context = _settings.Current.MatchSurroundingText
            ? InsertionContext.CaptureAsync(TimeSpan.FromMilliseconds(400))
            : Task.FromResult<InsertionContext?>(null);
        Context = null;
        _pieces.Clear();
        _partial = "";
        _micWarned = false;
        _peakLevel = 0;
        _sessionCts = new CancellationTokenSource();
        LastActivity = DateTime.Now;
        lock (_audioLock)
        {
            _recording = new MemoryStream();
            _waiting.Clear();
            _streaming = false;
        }
        SetState(DictationState.Starting);

        var profile = _profiles.Active;
        // Live typing needs the text to go straight in, so it is off for profiles that preview before inserting.
        // Nor when there is nowhere to type (the desktop, the taskbar): the text then waits for a click at the end.
        _live = _settings.Current.TypeWhileSpeaking && !profile.ShowPreview && !PasteSpot.IsNowhere(_target.Hwnd)
            ? new LiveInsertion(_inserter, _llm, _target, profile, _context, _spot)
            : null;

        // Were the models already loaded? A turnaround that includes loading one isn't a fair turnaround.
        _speechModelUsed = SpeechModels.For(profile, _settings.Current.Asr);
        _speechWarm = _asr.IsReady && string.Equals(_asr.LoadedModel, _speechModelUsed, StringComparison.OrdinalIgnoreCase);
        _aiModelUsed = !profile.AutoProcess ? "" : string.IsNullOrWhiteSpace(profile.Model) ? _settings.Current.Llm.DefaultModel : profile.Model!;
        _aiWarm = AiLoadedAsync(_aiModelUsed);

        // Start listening right away. If the speech model isn't loaded (first use, or unloaded after a while), it loads
        // meanwhile and catches up on what was said.
        _mic.Start(_settings.Current.MicrophoneName);
        _recordClock.Restart();
        SetState(DictationState.Recording);
        LiveTranscript?.Invoke("");
        _engine = StartEngineAsync(_live != null, SpeechModels.For(profile, _settings.Current.Asr), _sessionCts.Token);
        _ = WatchEngineAsync(_engine);
        // The AI model too, so the cleanup at the end doesn't wait for it to load.
        if (profile.AutoProcess) _ = _llm.WarmUpAsync(profile.Model);

        _maxDuration = new CancellationTokenSource();
        var token = _maxDuration.Token;
        _ = Task.Delay(TimeSpan.FromSeconds(Math.Max(10, _settings.Current.MaxRecordingSeconds)), token).ContinueWith(t =>
        {
            if (t.IsCanceled || State != DictationState.Recording) return;
            OnUi(async () =>
            {
                Notice?.Invoke("Maximum recording length reached; finishing up.", NoticeLevel.Info);
                try { await StopAsync(); } catch (Exception e) { Fail(e); }
            });
        }, TaskScheduler.Default);
        await Task.CompletedTask;
    }

    /// <summary>Whether the AI model is in memory right now (no AI, or a cloud model: nothing to load).</summary>
    async Task<bool> AiLoadedAsync(string model)
    {
        if (model.Length == 0 || CloudModels.IsCloud(model)) return true;
        try
        {
            var loaded = await _llm.LoadedModelsAsync();
            return loaded.Any(n => string.Equals(n, model, StringComparison.OrdinalIgnoreCase)
                                   || string.Equals(n, model + ":latest", StringComparison.OrdinalIgnoreCase));
        }
        catch { return false; }
    }

    /// <summary>Load the speech engine if needed, then hand it the session and everything recorded so far.</summary>
    /// <param name="model">The profile's speech model; another loaded model is swapped for it.</param>
    async Task StartEngineAsync(bool live, string model, CancellationToken ct)
    {
        if (!_asr.IsReady || !string.Equals(_asr.LoadedModel, model, StringComparison.OrdinalIgnoreCase))
        {
            EngineLoading?.Invoke(true);
            // Not cancelled with the dictation: a model half loaded would only have to load again next time.
            try { await _asr.InitializeAsync(model, CancellationToken.None); }
            finally { EngineLoading?.Invoke(false); }
        }
        ct.ThrowIfCancellationRequested();
        lock (_audioLock)
        {
            _asr.Start(live);
            foreach (var chunk in _waiting) _asr.AcceptAudio(chunk);
            _waiting.Clear();
            _streaming = true;
        }
    }

    /// <summary>The engine failed to start while the user was still speaking: say so now, not at the end.</summary>
    async Task WatchEngineAsync(Task engine)
    {
        try { await engine; }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (State == DictationState.Recording && engine == _engine) Fail(e); }
    }

    async Task StopAsync()
    {
        _maxDuration?.Cancel();
        _mic.Stop();
        _recordClock.Stop();
        _finishClock.Restart();
        var ct = _sessionCts?.Token ?? CancellationToken.None;
        SetState(DictationState.Transcribing);

        await _engine; // if the model was still loading, it now catches up on the whole recording
        var raw = OutputSanitizer.CollapseDots(await _asr.StopAsync(ct));
        ct.ThrowIfCancellationRequested();
        Context = await _context;
        if (_live != null) await _live.DrainAsync(); // let pieces already on their way finish typing
        if (_live?.HasTyped != true && SpeechGuard.ShouldDiscard(raw, _recordClock.Elapsed, _peakLevel))
        {
            if (OutputSanitizer.HasContent(raw))
                Log.Info($"Discarded a likely phantom transcript ({raw.Length} chars, {_recordClock.Elapsed.TotalSeconds:0.0} s, peak {_peakLevel:0.00})");
            LastActivity = DateTime.Now;
            SetState(DictationState.Idle);
            Notice?.Invoke("I didn't catch anything. Try again.", NoticeLevel.Info);
            return;
        }

        raw = Stitch(raw);
        var profile = _profiles.Active;
        var processed = raw;
        _pendingRaw = raw;
        _pendingProfile = profile.Name;
        _pendingSafetyNet = false;
        _pendingNote = null;
        _pendingAiEdit = null;
        if (profile.AutoProcess)
        {
            SetState(DictationState.Processing); // with live typing, this is the final pass over the whole recording
            try
            {
                var result = await _llm.ProcessAsync(raw, profile, ct);
                processed = result.Text;
                if (result.Modified) _pendingAiEdit = processed;
                // A safety-net rejection is reported on the receipt instead of as a separate notice.
                if (result.SafetyNet) { _pendingSafetyNet = true; _pendingNote = result.Warning; }
                else if (result.Warning != null) Notice?.Invoke(result.Warning, NoticeLevel.Warning);
            }
            catch (UserFacingException e) when (!ct.IsCancellationRequested)
            {
                // Never lose the user's words because the AI failed.
                Log.Warn("LLM step failed: " + e.Message);
                Notice?.Invoke(e.Message + " Inserting your original words.", NoticeLevel.Warning);
            }
        }

        ct.ThrowIfCancellationRequested(); // cancelled from the overlay while the AI was working: insert nothing
        _pendingRaw = raw;
        _pendingProcessed = processed;
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
        _pendingAiEdit = null; // the original words, not the AI's
        try { await InsertPendingAsync(_pendingRaw); } catch (Exception e) { Fail(e); }
    }

    async Task InsertPendingAsync(string text)
    {
        // Nothing had the cursor when the dictation started: ask where it should go instead of pasting into nowhere.
        if (_live?.HasTyped != true && (await _spot).Kind == PasteSpotKind.None)
        {
            WaitForPlace(text);
            return;
        }
        SetState(DictationState.Inserting);
        InsertReceipt? receipt = null;
        var inserted = false;
        var live = _live;
        try
        {
            var ct = _sessionCts?.Token ?? CancellationToken.None;
            if (_live?.HasTyped == true)
            {
                // Replace what was typed while speaking with the final pass over the whole recording.
                var (final, note) = await _live.FinishAsync(text, _asr.FinalTail, ct);
                text = final;
                _pendingNote = note ?? _pendingNote;
            }
            else
            {
                // A rewrite was laid out on purpose: only fix the spacing around it.
                var profile = _profiles.Active;
                text = ContextFit.Fit(text, await _context, spacingOnly: profile.RewriteWhole && profile.AutoProcess && text != _pendingRaw);
                await _inserter.InsertAsync(text, _target, ct, spot: await _spot);
            }
            inserted = true;
            receipt = new InsertReceipt(_pendingRaw, text, _finishClock.Elapsed, _pendingSafetyNet, _pendingNote, _pendingAiEdit, Context);
        }
        catch (UserFacingException e)
        {
            // Last resort so the dictation isn't lost: leave it on the clipboard.
            live?.ForgetClipboard();
            try { System.Windows.Clipboard.SetText(text); } catch { }
            Notice?.Invoke(e.Message + " The text was copied to your clipboard.", NoticeLevel.Warning);
        }
        finally
        {
            if (live != null) _ = live.ReleaseClipboardAsync(); // the user's clipboard, back once the last paste landed (no-op if forgotten)
            SaveToHistory(text, inserted);
            _pendingProcessed = _pendingRaw = "";
            _pendingSafetyNet = false;
            _live = null;
            LastActivity = DateTime.Now;
            SetState(DictationState.Idle);
        }
        if (receipt != null) Inserted?.Invoke(receipt);
    }

    void SaveToHistory(string final, bool inserted)
    {
        byte[] pcm;
        lock (_audioLock) pcm = _recording.ToArray();
        var entry = new HistoryEntry
        {
            Time = DateTime.Now - _finishClock.Elapsed - _recordClock.Elapsed,
            Profile = _pendingProfile,
            App = _target.ProcessName,
            WindowTitle = _target.Title,
            Transcript = _pendingRaw,
            AiOutput = _pendingAiEdit,
            Final = final.Trim(),
            WasInserted = inserted,
            SafetyNet = _pendingSafetyNet,
            Note = _pendingNote,
            Seconds = Math.Round(_recordClock.Elapsed.TotalSeconds, 1),
            FinishSeconds = Math.Round(_finishClock.Elapsed.TotalSeconds, 2),
        };
        _history.Add(entry, pcm);
        _usage?.Record(entry);
        _tally?.Record(entry);
        // The dashboard's turnaround: only a dictation that went straight in counts (not one that waited for a click).
        if (inserted && !_placed && entry.FinishSeconds > 0)
            _usage?.RecordTurnaround(new TurnaroundSample
            {
                Time = DateTime.Now, SpeechModel = _speechModelUsed, AiModel = _aiModelUsed, Seconds = entry.FinishSeconds,
                ModelLoaded = !_speechWarm || !(_aiWarm.IsCompletedSuccessfully && _aiWarm.Result),
            });
    }

    // ===== nowhere to type: wait for a click, or copy =====

    /// <summary>How long the text waits for a click before it is copied to the clipboard instead.</summary>
    static readonly TimeSpan PlaceTimeout = TimeSpan.FromMinutes(2);

    void WaitForPlace(string text)
    {
        _placingText = text.Trim();
        _finishClock.Stop(); // waiting for the user isn't processing time
        _live?.Stop();
        _live = null;
        _placeCts = new CancellationTokenSource();
        SetState(DictationState.Placing);
        _ = WatchForPlaceAsync(_placeCts.Token);
    }

    /// <summary>
    /// Watch for the user clicking into somewhere to type: a window that isn't the desktop or taskbar, whose focused
    /// control can take text, once the mouse is released and the focus has settled. Then the text goes in there.
    /// </summary>
    async Task WatchForPlaceAsync(CancellationToken ct)
    {
        var deadline = DateTime.Now + PlaceTimeout;
        var seen = IntPtr.Zero;
        var steady = 0;
        try
        {
            while (DateTime.Now < deadline)
            {
                await Task.Delay(250, ct);
                var fg = Native.GetForegroundWindow();
                if (PasteSpot.IsNowhere(fg) || PasteSpot.MouseDown || fg != seen) { seen = fg; steady = 0; continue; }
                if (++steady < 2) continue;
                var target = InsertionTarget.Capture();
                var spot = await PasteSpot.CaptureAsync(target, TimeSpan.FromMilliseconds(400));
                ct.ThrowIfCancellationRequested();
                if (spot.Kind == PasteSpotKind.None || State != DictationState.Placing) continue;
                Log.Info($"Placing the dictation where the user clicked: {target.ProcessName}");
                _target = target;
                _spot = Task.FromResult(spot);
                _placed = true;
                _placeCts = null;
                _finishClock.Start();
                try { await InsertPendingAsync(_placingText); } catch (Exception e) { Fail(e); }
                return;
            }
            CopyPlacingToClipboard(timedOut: true);
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Placing: the overlay's Copy button or the hotkey (or the wait ran out): the text goes to the clipboard.</summary>
    public void CopyPlacingToClipboard(bool timedOut = false)
    {
        if (State != DictationState.Placing) return;
        _placeCts?.Cancel();
        _placeCts = null;
        try
        {
            // Like a paste: not into Windows clipboard history or cloud sync.
            var data = new System.Windows.DataObject();
            data.SetText(_placingText, System.Windows.TextDataFormat.UnicodeText);
            data.SetData("CanIncludeInClipboardHistory", new MemoryStream(new byte[4]));
            data.SetData("CanUploadToCloudClipboard", new MemoryStream(new byte[4]));
            System.Windows.Clipboard.SetDataObject(data, true);
        }
        catch (Exception e) { Log.Warn("Copying the dictation failed: " + e.Message); }
        SaveToHistory(_placingText, false);
        _pendingProcessed = _pendingRaw = "";
        _pendingSafetyNet = false;
        LastActivity = DateTime.Now;
        SetState(DictationState.Idle);
        Notice?.Invoke(timedOut
            ? "No place to paste was chosen, so the text was copied to your clipboard."
            : "Copied to your clipboard. Paste it wherever you like.", NoticeLevel.Info);
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
                _sessionCts?.Cancel(); // a recognizer still loading must not start a session afterwards
                _asr.Cancel();
                break;
            case DictationState.Confirming:
                break;
            case DictationState.Placing:
                _placeCts?.Cancel();
                _placeCts = null;
                SaveToHistory(_placingText, false); // discarded, but kept in History in case
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
        _pendingProcessed = _pendingRaw = "";
        LastActivity = DateTime.Now;
        SetState(DictationState.Idle);
    }

    /// <summary>Insert arbitrary text (e.g. a version from History) into the last target. The window in front when
    /// asked (Oberton, usually) comes back to the front afterwards, so the text goes in behind it.</summary>
    /// <returns>The name of the app it went into.</returns>
    public async Task<string> InsertIntoLastTargetAsync(string text)
    {
        var front = Native.GetForegroundWindow();
        var target = _target;
        await _inserter.InsertAsync(text, target);
        if (front != IntPtr.Zero && front != target.Hwnd && Native.IsWindow(front))
        {
            await Task.Delay(250); // the paste lands first
            await _inserter.FocusAsync(new InsertionTarget(front, 0, "", ""));
        }
        return target.DisplayName;
    }
}
