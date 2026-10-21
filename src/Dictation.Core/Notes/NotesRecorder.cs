using System.Diagnostics;
using System.Windows.Threading;
using Dictation.Core.Audio;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Setup;
using Dictation.Core.Speech;
using Dictation.Core.Text;
using NAudio.Wave;

namespace Dictation.Core.Notes;

/// <summary>
/// Runs an Extended Notes session: listens (mic, computer audio or both), writes the recording, sends it to the speech
/// engine on a connection of its own, appends each finished piece to the transcript, formats the new text with the AI
/// about every minute, sums it up every 5 to 10 minutes (<see cref="NotesSummary"/>), and saves as it goes. Only one
/// session records at a time. Normal dictation pauses it (<see cref="SetDictating"/>). Create and use on the UI thread.
/// </summary>
public sealed class NotesRecorder
{
    /// <summary>Format once this many new words have come in, or after <see cref="FormatEvery"/> with at least a few.</summary>
    const int FormatWords = 110;
    static readonly TimeSpan FormatEvery = TimeSpan.FromSeconds(90);

    readonly SettingsService _settings;
    readonly ISpeechRecognizer _asr;
    readonly ITextProcessor _llm;
    readonly NotesStore _store;
    readonly Func<string> _speechModel;

    MicCapture? _mic;
    LoopbackCapture? _loopback;
    readonly NotesMixer _mixer = new();
    Timer? _computerClock;
    readonly Stopwatch _computerWatch = new();
    long _computerEmitted;

    WaveFileWriter? _wav;
    readonly object _wavLock = new();
    long _samples; // recorded, pauses not counted
    SpeechSessionClient? _speech;
    // Audio that arrives while the engine isn't connected (still loading, or the connection dropped) waits here, up to
    // three minutes of it, and goes out as soon as it is: the transcript has no gap. The lock guards _speech too.
    readonly object _audioLock = new();
    readonly Queue<byte[]> _backlog = new();
    long _backlogBytes;
    const long MaxBacklogBytes = MicCapture.SampleRate * 2L * 180;
    bool _connecting;
    DateTime _nextConnect = DateTime.MinValue;
    TimeSpan _connectDelay = TimeSpan.FromSeconds(5);
    DispatcherTimer? _tick;
    double _lastPieceSeconds;
    bool _userPaused, _dictating, _formatting, _summarizing, _dirty;
    int _formatRequests, _summaryRequests; // this session's AI requests, for the counts
    string? _model;          // the AI model formatting and summaries use, as last resolved
    string _modelFor = "";   // the setting it was resolved from
    DateTime _modelResolved;
    DateTime _lastFormat = DateTime.Now, _lastSave = DateTime.Now, _lastSection = DateTime.Now;

    public NotesRecorder(SettingsService settings, ISpeechRecognizer asr, ITextProcessor llm, NotesStore store, Func<string> speechModel)
    {
        _settings = settings; _asr = asr; _llm = llm; _store = store; _speechModel = speechModel;
    }

    /// <summary>The session recording now; null when none is.</summary>
    public NoteSession? Current { get; private set; }
    public bool IsRecording => Current != null;
    /// <summary>Recording, or redoing a step: either way the speech engine and the AI model are in use, so nothing
    /// may unload them.</summary>
    public bool NeedsModels => Current != null || Redoing != null;
    /// <summary>Paused by the user (Pause), not by a dictation.</summary>
    public bool UserPaused => _userPaused;
    /// <summary>Not recording right now: paused by the user, or while a dictation runs.</summary>
    public bool IsPaused => _userPaused || _dictating;
    /// <summary>Stop was pressed: the last piece is being transcribed and formatted.</summary>
    public bool IsFinishing { get; private set; }
    /// <summary>Seconds recorded in the current session.</summary>
    public double Seconds => Interlocked.Read(ref _samples) / (double)MicCapture.SampleRate;
    /// <summary>The engine is listening (connected); false while it reconnects.</summary>
    public bool Transcribing => _speech?.IsConnected == true;
    /// <summary>The AI is formatting a part right now.</summary>
    public bool IsFormatting => _formatting;
    /// <summary>The AI is summing up right now (a section, a merge or the Summary tab).</summary>
    public bool IsSummarizing => _summarizing;
    /// <summary>The AI model this session formats and sums up with, once it has been worked out; null before.</summary>
    public string? Model => _model;

    /// <summary>Recording started, paused, resumed or stopped (UI thread).</summary>
    public event Action? StateChanged;

    static void OnUi(Action a) => System.Windows.Application.Current?.Dispatcher.BeginInvoke(a);

    public async Task StartAsync(NotesSource source)
    {
        if (IsRecording) return;
        if (Redoing != null)
            throw new UserFacingException("A session is being redone. Wait for it to finish, or stop it from its pipeline, then start a new one.");
        var s = _store.Create(source);
        Interlocked.Exchange(ref _samples, 0);
        _lastPieceSeconds = 0;
        _userPaused = _formatting = _summarizing = false;
        _formatRequests = _summaryRequests = 0;
        _model = null;
        _connectDelay = TimeSpan.FromSeconds(5);
        lock (_audioLock) { _backlog.Clear(); _backlogBytes = 0; }
        _lastFormat = _lastSave = _lastSection = DateTime.Now;
        try
        {
            lock (_wavLock) _wav = new WaveFileWriter(s.AudioPath, new WaveFormat(MicCapture.SampleRate, 16, 1));
            StartAudio(source);
        }
        catch
        {
            StopAudio();
            CloseWav();
            _store.Delete(s);
            throw;
        }
        // What was typed in the dashboard's notes box beforehand begins the transcript, as the user's own notes.
        var draft = _store.TakeDraft().Trim();
        if (draft.Length > 0)
        {
            s.Set(NoteDoc.Transcript, draft + "\n", this);
            _store.Save(s);
        }
        Current = s;
        Log.Info($"Extended notes: started {s.Id} ({source})");
        _tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _tick.Tick += (_, _) => Tick();
        _tick.Start();
        StateChanged?.Invoke();
        await ConnectSpeechAsync();
    }

    void StartAudio(NotesSource source)
    {
        if (source is NotesSource.Computer or NotesSource.Both)
        {
            _loopback = new LoopbackCapture();
            _loopback.Samples += _mixer.AddComputer;
            _loopback.Start();
        }
        if (source is NotesSource.Mic or NotesSource.Both)
        {
            _mic = new MicCapture();
            _mic.DataAvailable += chunk => OnPcm(source == NotesSource.Both ? _mixer.MixWithMic(chunk) : chunk);
            _mic.Start(_settings.Current.MicrophoneName);
        }
        else
        {
            // Computer audio alone: Windows sends nothing during silence, so a clock paces the stream.
            _computerEmitted = 0;
            _computerWatch.Restart();
            _computerClock = new Timer(_ =>
            {
                var due = (long)(_computerWatch.Elapsed.TotalSeconds * MicCapture.SampleRate) - _computerEmitted;
                if (due <= 0) return;
                _computerEmitted += due;
                OnPcm(_mixer.TakeComputer((int)due));
            }, null, 100, 100);
        }
    }

    /// <summary>16 kHz mono 16-bit audio, on a capture thread: into the recording and to the speech engine.</summary>
    void OnPcm(byte[] pcm)
    {
        if (Current == null || IsPaused || IsFinishing) return;
        lock (_wavLock) _wav?.Write(pcm, 0, pcm.Length);
        lock (_audioLock)
        {
            if (_speech is { IsConnected: true } speech) speech.Send(pcm);
            else
            {
                _backlog.Enqueue(pcm);
                _backlogBytes += pcm.Length;
                while (_backlogBytes > MaxBacklogBytes) _backlogBytes -= _backlog.Dequeue().Length;
            }
        }
        Interlocked.Add(ref _samples, pcm.Length / 2);
    }

    async Task ConnectSpeechAsync()
    {
        if (_connecting || Current == null) return;
        _connecting = true;
        try
        {
            if (!_asr.IsReady) await _asr.InitializeAsync(_speechModel(), CancellationToken.None);
            var client = new SpeechSessionClient();
            client.Committed += text => OnUi(() => OnPiece(text));
            client.Disconnected += () => OnUi(() =>
            {
                bool mine;
                lock (_audioLock) { mine = _speech == client; if (mine) _speech = null; }
                if (mine) StateChanged?.Invoke();
            });
            await client.ConnectAsync(_settings.Current.Asr.Port, CancellationToken.None);
            var asr = _settings.Current.Asr;
            client.Start(asr.Language, asr.VocabularyHint, even: asr.EvenOutVolume);
            if (Current == null) { await client.DisposeAsync(); return; }
            int waiting;
            lock (_audioLock)
            {
                // What was said meanwhile goes first; the live audio follows on.
                waiting = _backlog.Count;
                while (_backlog.Count > 0) client.Send(_backlog.Dequeue());
                _backlogBytes = 0;
                _speech = client;
            }
            _connectDelay = TimeSpan.FromSeconds(5);
            Log.Info("Extended notes: listening" + (waiting > 0 ? $" ({waiting} waiting pieces of audio sent first)" : ""));
            StateChanged?.Invoke();
        }
        catch (Exception e)
        {
            // Each try may load the model, so the tries space out: 5 s, 10 s, 20 s, up to a minute apart.
            Log.Warn($"Extended notes: couldn't connect to the speech engine ({e.Message}); next try in {_connectDelay.TotalSeconds:0} s");
            _nextConnect = DateTime.Now + _connectDelay;
            _connectDelay = TimeSpan.FromSeconds(Math.Min(60, _connectDelay.TotalSeconds * 2));
        }
        finally { _connecting = false; }
    }

    /// <summary>A finished piece of speech (UI thread).</summary>
    void OnPiece(string text)
    {
        var s = Current;
        if (s == null) return;
        // The piece began about where the last one ended; it is reported a moment after it was said.
        s.AppendHeard(text, _lastPieceSeconds, this);
        _lastPieceSeconds = Math.Max(_lastPieceSeconds, Seconds - 1.0);
        _dirty = true;
    }

    void Tick()
    {
        var s = Current;
        if (s == null || IsFinishing) return;
        s.Seconds = Seconds;
        if (_speech == null && !_connecting && DateTime.Now >= _nextConnect) _ = ConnectSpeechAsync();
        if (!_dictating)
        {
            // Not while a dictation runs: its AI edit would wait behind a long formatting or summary request.
            MaybeFormat(s);
            MaybeSummarize(s);
        }
        if (_dirty && DateTime.Now - _lastSave > TimeSpan.FromSeconds(10)) Save(s);
        else if (DateTime.Now - _lastSave > TimeSpan.FromSeconds(30)) Save(s); // the recording's length, at least
        StateChanged?.Invoke(); // the timer
    }

    void Save(NoteSession s)
    {
        lock (_wavLock) { try { _wav?.Flush(); } catch (Exception e) { Log.Warn("Extended notes: flushing audio failed: " + e.Message); } }
        _store.Save(s);
        _dirty = false;
        _lastSave = DateTime.Now;
    }

    void MaybeFormat(NoteSession s)
    {
        if (_formatting) return;
        var words = s.UnformattedWords();
        if (words >= FormatWords || words >= 15 && DateTime.Now - _lastFormat >= FormatEvery) _ = FormatAsync(s);
    }

    async Task FormatAsync(NoteSession s, int? maxWords = null)
    {
        if (_formatting) return;
        var take = maxWords is { } most ? s.BeginFormatPart(most) : s.BeginFormat();
        if (take == null) return;
        _formatting = true;
        var (heard, sent, seconds) = take.Value;
        // The speech engine's loops ("Thank you." forty times) go before anything else: the AI would copy them.
        var input = NotesFormat.CollapseRepeats(sent);
        string ai = input;
        var failed = true;
        try
        {
            // Nothing but markers since the last step (Stop right after one): nothing for the AI to tidy.
            if (OnlyMarkers(sent)) { ai = sent; failed = false; }
            else
            {
                _formatRequests++;
                var reply = await _llm.AskAsync(NotesFormat.Instructions(input), NotesFormat.Wrap(input), NotesFormat.MaxTokens(input), await ModelAsync());
                if (NotesFormat.Accept(input, reply) is { } accepted) { ai = accepted; failed = false; }
                else Log.Info("Extended notes: the AI's formatting added to, dropped or changed the text; keeping it as heard");
            }
        }
        catch (Exception e) { Log.Warn("Extended notes: formatting failed, keeping the text as heard: " + e.Message); }
        finally
        {
            s.EndFormat(heard, sent, ai, seconds, failed, this);
            _lastFormat = DateTime.Now;
            _formatting = false;
            _dirty = true;
        }
    }

    // ===== redoing a finished session's steps =====

    /// <summary>The step being redone (null when none is), for which session, and how far it got.</summary>
    public NotesRedo.Step? Redoing { get; private set; }
    public NoteSession? RedoSession { get; private set; }
    public string RedoProgress { get; private set; } = "";
    CancellationTokenSource? _redo;

    /// <summary>Stop the redo running now; what is done so far stays (a transcript is only replaced once it is whole).</summary>
    public void CancelRedo() => _redo?.Cancel();

    /// <summary>
    /// Redo a step of a finished session, and every step after it: transcribe the recording again (then format and sum
    /// up again), format the whole transcript again (then sum up again), or sum up again. Not while a session records.
    /// Saved as it goes; cancelled by <see cref="CancelRedo"/>.
    /// </summary>
    public async Task RedoAsync(NoteSession s, NotesRedo.Step step)
    {
        if (IsRecording) throw new UserFacingException("A step can be redone once the session recording now has stopped.");
        if (Redoing != null) throw new UserFacingException("Another step is being redone; wait for it to finish.");
        _redo = new CancellationTokenSource();
        var ct = _redo.Token;
        RedoSession = s;
        _model = null;
        Log.Info($"Extended notes: redoing {step} for {s.Id}");
        try
        {
            if (step == NotesRedo.Step.Transcribe)
            {
                Redoing = NotesRedo.Step.Transcribe;
                StateChanged?.Invoke();
                await RetranscribeAsync(s, ct);
            }
            if (step <= NotesRedo.Step.Format)
            {
                Redoing = NotesRedo.Step.Format;
                RedoProgress = "";
                StateChanged?.Invoke();
                s.ResetFormatting(this);
                _store.Save(s);
                var parts = 0;
                while (s.Transcript[Math.Min(s.FormattedThrough, s.Transcript.Length)..].Trim().Length > 0)
                {
                    ct.ThrowIfCancellationRequested();
                    RedoProgress = $"{s.FormattedThrough * 100 / Math.Max(1, s.Transcript.Length)}%";
                    var before = s.FormattedThrough;
                    await FormatAsync(s, FormatWords);
                    if (s.FormattedThrough <= before) break; // nothing taken: don't loop
                    if (++parts % 5 == 0) _store.Save(s);
                }
            }
            ct.ThrowIfCancellationRequested();
            Redoing = NotesRedo.Step.Summary;
            RedoProgress = "";
            StateChanged?.Invoke();
            s.ResetSummary(this);
            await SummarizeAsync(s, final: true);
            Log.Info($"Extended notes: redid {step} for {s.Id}");
        }
        finally
        {
            Redoing = null;
            RedoSession = null;
            RedoProgress = "";
            _redo = null;
            _store.Save(s);
            StateChanged?.Invoke();
            _ = ReleaseModelAsync();
        }
    }

    /// <summary>The recording, transcribed again part by part (cut in its pauses), on a connection of its own. The
    /// transcript is replaced only once every part is done, so a cancelled redo changes nothing.</summary>
    async Task RetranscribeAsync(NoteSession s, CancellationToken ct)
    {
        if (!File.Exists(s.AudioPath)) throw new UserFacingException("This session has no recording to transcribe again.");
        RedoProgress = "reading the recording";
        var pauses = await Task.Run(() => NotesAudio.Pauses(s.AudioPath), ct);
        using var reader = new WaveFileReader(s.AudioPath);
        var format = reader.WaveFormat;
        if (format.Encoding != WaveFormatEncoding.Pcm || format.BitsPerSample != 16 || format.Channels != 1 || format.SampleRate != MicCapture.SampleRate)
            throw new UserFacingException("This recording isn't in the format the speech engine takes (16 kHz mono).");
        var parts = NotesRedo.PlanParts(reader.TotalTime.TotalSeconds, pauses);
        if (!_asr.IsReady) await _asr.InitializeAsync(_speechModel(), ct);
        var client = await ConnectForRedoAsync(ct);
        var asr = _settings.Current.Asr;
        var pieces = new List<(double Seconds, string Text)>();
        var previous = "";
        var buffer = new byte[32000];
        try
        {
            for (var i = 0; i < parts.Count; i++)
            {
                ct.ThrowIfCancellationRequested();
                RedoProgress = $"{i * 100 / parts.Count}%";
                var (start, end) = parts[i];
                // The end of the part before keeps names and casing consistent (loops left out, as live).
                var tail = NotesFormat.CollapseRepeats(previous);
                tail = tail.Length > 200 ? tail[^200..] : tail;
                var prompt = string.Join(" ", new[] { asr.VocabularyHint, tail }.Where(p => !string.IsNullOrWhiteSpace(p)));
                string? text = null;
                for (var attempt = 0; text == null; attempt++)
                {
                    if (!client.IsConnected)
                    {
                        // The engine went away (it restarted, or was unloaded): bring it back and do this part again.
                        if (attempt > 2) throw new UserFacingException("The speech engine kept stopping while transcribing again; nothing was changed.");
                        Log.Warn($"Extended notes: the speech engine stopped at part {i + 1} of {parts.Count}; reconnecting");
                        await client.DisposeAsync();
                        await Task.Delay(TimeSpan.FromSeconds(2 * attempt), ct);
                        client = await ConnectForRedoAsync(ct);
                    }
                    client.Start(asr.Language, prompt.Length > 0 ? prompt : null, live: false, dropPhantoms: true, even: asr.EvenOutVolume);
                    reader.Position = (long)(start * format.SampleRate) * format.BlockAlign;
                    var left = (long)((end - start) * format.SampleRate) * format.BlockAlign;
                    while (left > 0)
                    {
                        var n = reader.Read(buffer, 0, (int)Math.Min(buffer.Length, left));
                        if (n <= 0) break;
                        client.Send(buffer[..n]);
                        left -= n;
                    }
                    var heard = (await client.StopAsync(TimeSpan.FromSeconds(Math.Max(60, (end - start) * 4)))).Trim();
                    if (client.IsConnected) text = heard;
                }
                if (text.Length > 0)
                {
                    pieces.Add((start, text));
                    previous = text;
                }
            }
        }
        finally { await client.DisposeAsync(); }
        ct.ThrowIfCancellationRequested();
        s.ReplaceTranscript(pieces, this);
        _store.Save(s);
        Log.Info($"Extended notes: transcribed {s.Id} again in {parts.Count} parts");
    }

    /// <summary>A connection of the redo's own to the speech engine, loading it first if it isn't running.</summary>
    async Task<SpeechSessionClient> ConnectForRedoAsync(CancellationToken ct)
    {
        if (!_asr.IsReady) await _asr.InitializeAsync(_speechModel(), ct);
        var client = new SpeechSessionClient();
        try { await client.ConnectAsync(_settings.Current.Asr.Port, ct); }
        catch
        {
            await client.DisposeAsync();
            throw;
        }
        return client;
    }

    /// <summary>Every line is a marker's (or blank).</summary>
    static bool OnlyMarkers(string text) =>
        text.Split('\n').All(l => l.Trim().Length == 0 || l.TrimStart().StartsWith(NoteSession.MarkerFlag, StringComparison.Ordinal));

    /// <summary>Every 5 to 10 minutes of speech: sum up the new formatted text, fold summaries together when they pile up,
    /// and write the Summary tab afresh. See <see cref="NotesSummary"/>.</summary>
    void MaybeSummarize(NoteSession s)
    {
        if (_summarizing || _formatting) return;
        var fresh = s.UnsummarizedChars();
        if (fresh >= NotesSummary.SectionChars || fresh >= NotesSummary.SectionMinChars && DateTime.Now - _lastSection >= NotesSummary.SectionEvery)
            _ = SummarizeAsync(s, final: false);
    }

    /// <summary>Sum up what is new (at Stop: everything left, however little), merge, and rewrite the summary.</summary>
    async Task SummarizeAsync(NoteSession s, bool final)
    {
        if (_summarizing) return;
        _summarizing = true;
        try
        {
            // 1. The new formatted text, a section at a time (never more than one request can take).
            int sections = 0, added = 0;
            while (sections < (final ? 50 : 1) && s.BeginSection(NotesSummary.InputBudget) is { } section)
            {
                sections++;
                var reply = await Ask(NotesSummary.DigestPrompt(NotesSummary.DigestWords(section.Text)), section.Text, NotesSummary.DigestTokens);
                if (!NotesSummary.IsUsable(section.Text, reply))
                {
                    s.EndSection(null, section.Start, section.End);
                    Log.Info("Extended notes: a section's summary was unusable; trying again next time");
                    break;
                }
                s.EndSection(reply, section.Start, section.End);
                _lastSection = DateTime.Now; added++;
                _dirty = true;
            }
            if (added == 0) return;

            // 2. Four summaries of one level become one, shorter; and so on up, so what is left always fits one request.
            for (var merges = 0; merges < 20 && NotesSummary.MergeGroup(s.Frontier()) is { } group; merges++)
            {
                var input = NotesSummary.MergeInput(group);
                var reply = await Ask(NotesSummary.MergePrompt(NotesSummary.MergeWords(group)), input, NotesSummary.MergeTokens);
                if (!NotesSummary.IsUsable(input, reply)) { Log.Info("Extended notes: merging summaries gave nothing usable; keeping them apart"); break; }
                s.Merge(group, reply);
                _dirty = true;
            }

            // 3. The Summary tab: the main idea, key points, at most three paragraphs; the listener's edits kept.
            var frontier = s.Frontier();
            if (frontier.Count == 0) return;
            var basedOn = s.Summary;
            var listener = basedOn.Trim() != s.SummaryByAi.Trim() ? basedOn : null;
            var text = NotesSummary.FinalInput(frontier, listener);
            var summary = NotesSummary.Shape(await Ask(NotesSummary.FinalPrompt, text, NotesSummary.FinalTokens));
            if (summary == null || NoteSession.Words(summary) > NoteSession.Words(text) * 1.5 + 60) Log.Info("Extended notes: the summary was unusable; keeping the last one");
            else if (!s.EndSummary(summary, basedOn, this)) Log.Info("Extended notes: the summary was edited meanwhile; keeping the edit");
            _dirty = true;
        }
        catch (Exception e) { Log.Warn("Extended notes: summarizing failed: " + e.Message); }
        finally { _summarizing = false; }
    }

    async Task<string> Ask(string instructions, string text, int maxTokens)
    {
        _summaryRequests++;
        return await _llm.AskAsync(instructions, text, maxTokens, await ModelAsync());
    }

    /// <summary>The AI model for formatting and summaries (see <see cref="NotesModels"/>): resolved again when the setting
    /// changes, and every ten minutes, since a model may have been downloaded or removed meanwhile.</summary>
    async Task<string> ModelAsync()
    {
        var setting = _settings.Current.NotesModel ?? "";
        if (_model != null && setting == _modelFor && DateTime.Now - _modelResolved < TimeSpan.FromMinutes(10)) return _model;
        var (model, why) = await NotesModels.ResolveAsync(setting, _settings.Current.Llm.DefaultModel,
            () => _llm.ListModelDetailsAsync(), RuntimeInstaller.GpuMemoryBytes(), LocalModel.SystemRam);
        if (model != _model) Log.Info($"Extended notes: AI model {model} ({why})");
        _model = model;
        _modelFor = setting;
        _modelResolved = DateTime.Now;
        return model;
    }

    public void Pause()
    {
        if (!IsRecording || _userPaused) return;
        _userPaused = true;
        Log.Info("Extended notes: paused");
        StateChanged?.Invoke();
    }

    public void Resume()
    {
        if (!IsRecording || !_userPaused) return;
        _userPaused = false;
        Log.Info("Extended notes: resumed");
        StateChanged?.Invoke();
    }

    /// <summary>The listener marked this moment (the hotkey, or the Mark button): a "⚑ h:mm:ss" line goes into the
    /// transcript, paused or not, and the session is saved. Nothing once Stop was pressed.</summary>
    public void AddMarker()
    {
        if (Current == null || IsFinishing) return;
        var at = Seconds;
        OnUi(() =>
        {
            var s = Current;
            if (s == null) return;
            s.AddMarker(at, this);
            Log.Info("Extended notes: marker at " + NoteSession.MarkerLabel(at));
            Save(s);
        });
    }

    /// <summary>A dictation started or ended: the session pauses while it runs (both would hear the same voice).</summary>
    public void SetDictating(bool dictating)
    {
        if (_dictating == dictating) return;
        _dictating = dictating;
        if (IsRecording) StateChanged?.Invoke();
    }

    /// <summary>Stop: the last piece is transcribed and formatted, the summary brought up to date, and the session saved.</summary>
    public async Task StopAsync()
    {
        var s = Current;
        if (s == null || IsFinishing) return;
        IsFinishing = true;
        StateChanged?.Invoke();
        StopAudio();
        _tick?.Stop();
        try
        {
            SpeechSessionClient? speech;
            lock (_audioLock)
            {
                speech = _speech;
                _speech = null;
                if (_backlogBytes > 0)
                    Log.Warn($"Extended notes: {_backlogBytes / 2 / MicCapture.SampleRate} s of audio never reached the speech engine (not connected); the recording has it");
                _backlog.Clear();
                _backlogBytes = 0;
            }
            if (speech != null)
            {
                var tail = await speech.StopAsync(TimeSpan.FromSeconds(60));
                if (tail.Trim().Length > 0) s.AppendHeard(tail, _lastPieceSeconds, this);
                await speech.DisposeAsync();
            }
            CloseWav();
            s.Seconds = Seconds;
            while (_formatting || _summarizing) await Task.Delay(200);
            if (s.UnformattedWords() > 0) await FormatAsync(s);
            await SummarizeAsync(s, final: true);
        }
        catch (Exception e) { Log.Error("Extended notes: finishing the session failed", e); }
        finally
        {
            s.Finished = true;
            _store.Save(s);
            _store.Usage.Record(s, _formatRequests, _summaryRequests);
            Current = null;
            IsFinishing = false;
            _userPaused = false;
            Log.Info($"Extended notes: stopped {s.Id} after {TimeSpan.FromSeconds(s.Seconds):h\\:mm\\:ss}");
            StateChanged?.Invoke();
            _ = ReleaseModelAsync();
        }
    }

    /// <summary>The session or redo is done: a model held in the PC's RAM (Qwen3 30B-A3B, a 27B) is let go at once,
    /// rather than holding ~20 GB of RAM until it times out. Not while another session or redo has started meanwhile.</summary>
    async Task ReleaseModelAsync()
    {
        var model = _model;
        if (model == null || NeedsModels) return;
        try { await _llm.ReleaseIfLargeAsync(model); }
        catch (Exception e) { Log.Warn("Extended notes: letting the AI model go failed: " + e.Message); }
    }

    /// <summary>Oberton is closing: keep everything up to now (and the dashboard draft; no last formatting pass), right away.</summary>
    public void Shutdown()
    {
        _store.FlushDraft();
        var s = Current;
        if (s == null) return;
        StopAudio();
        _tick?.Stop();
        try { _speech?.DisposeAsync().AsTask().Wait(1000); } catch { }
        lock (_audioLock) _speech = null;
        CloseWav();
        s.Seconds = Seconds;
        s.Finished = true;
        try { File.WriteAllText(Path.Combine(s.Folder, "session.json"), System.Text.Json.JsonSerializer.Serialize(s, JsonStore.Options)); }
        catch (Exception e) { Log.Warn("Extended notes: saving at exit failed: " + e.Message); }
        _store.Usage.Record(s, _formatRequests, _summaryRequests);
        Current = null;
    }

    void StopAudio()
    {
        _computerClock?.Dispose();
        _computerClock = null;
        _mic?.Dispose();
        _mic = null;
        _loopback?.Dispose();
        _loopback = null;
    }

    void CloseWav()
    {
        lock (_wavLock)
        {
            try { _wav?.Dispose(); } catch (Exception e) { Log.Warn("Extended notes: closing the recording failed: " + e.Message); }
            _wav = null;
        }
    }
}
