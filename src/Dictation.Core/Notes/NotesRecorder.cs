using System.Diagnostics;
using System.Windows.Threading;
using Dictation.Core.Audio;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Dictation.Core.Text;
using NAudio.Wave;

namespace Dictation.Core.Notes;

/// <summary>
/// Runs an Extended Notes session: listens (mic, computer audio or both), writes the recording, sends it to the speech
/// engine on a connection of its own, appends each finished piece to the transcript, formats the new text with the AI
/// about every minute, keeps a running summary, and saves as it goes. Only one session records at a time. Normal
/// dictation pauses it (<see cref="SetDictating"/>). Create and use on the UI thread.
/// </summary>
public sealed class NotesRecorder
{
    /// <summary>Format once this many new words have come in, or after <see cref="FormatEvery"/> with at least a few.</summary>
    const int FormatWords = 110;
    static readonly TimeSpan FormatEvery = TimeSpan.FromSeconds(90);
    /// <summary>Update the summary once this much new formatted text (about five minutes of speech) has come in.</summary>
    const int SummaryChars = 2500;

    public const string FormatPrompt =
        "You are formatting a live transcript of a lecture or meeting, one part at a time. Fix punctuation and " +
        "capitalization, remove filler words, false starts and words said twice, and split the text into paragraphs " +
        "where the topic changes. Keep every point, name and number and the speaker's own wording: do not summarize, " +
        "shorten, add headings or add anything that was not said. Some lines are notes the listener typed: keep them " +
        "exactly as written, on their own line.";

    public const string SummaryPrompt =
        "You keep the running summary of a long lecture or meeting. The input has two parts: CURRENT SUMMARY and NEW " +
        "PART. Reply with the updated summary only: everything the current summary says (keep its wording where it is " +
        "still right, including anything the listener wrote in it), with the main points, decisions, names, numbers and " +
        "open questions of the new part folded in. Plain text in short paragraphs or lines starting with \"- \"; no " +
        "headings, no preface. Keep it concise.";

    static readonly Profile FormatProfile = new()
    {
        Name = "Extended notes: format", Prompt = FormatPrompt, AutoProcess = true, RewriteWhole = true,
        PreserveParagraphs = true, RemoveFillers = true,
    };

    static readonly Profile SummaryProfile = new()
    {
        Name = "Extended notes: summary", Prompt = SummaryPrompt, AutoProcess = true, RewriteWhole = true,
        PreserveParagraphs = true, RemoveFillers = false,
    };

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
    bool _connecting;
    DateTime _nextConnect = DateTime.MinValue;
    DispatcherTimer? _tick;
    double _lastPieceSeconds;
    bool _userPaused, _dictating, _formatting, _summarizing, _dirty;
    DateTime _lastFormat = DateTime.Now, _lastSave = DateTime.Now;

    public NotesRecorder(SettingsService settings, ISpeechRecognizer asr, ITextProcessor llm, NotesStore store, Func<string> speechModel)
    {
        _settings = settings; _asr = asr; _llm = llm; _store = store; _speechModel = speechModel;
    }

    /// <summary>The session recording now; null when none is.</summary>
    public NoteSession? Current { get; private set; }
    public bool IsRecording => Current != null;
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

    /// <summary>Recording started, paused, resumed or stopped (UI thread).</summary>
    public event Action? StateChanged;

    static void OnUi(Action a) => System.Windows.Application.Current?.Dispatcher.BeginInvoke(a);

    public async Task StartAsync(NotesSource source)
    {
        if (IsRecording) return;
        var s = _store.Create(source);
        Interlocked.Exchange(ref _samples, 0);
        _lastPieceSeconds = 0;
        _userPaused = _formatting = _summarizing = false;
        _lastFormat = _lastSave = DateTime.Now;
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
        _speech?.Send(pcm);
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
            client.Disconnected += () => OnUi(() => { if (_speech == client) { _speech = null; StateChanged?.Invoke(); } });
            await client.ConnectAsync(_settings.Current.Asr.Port, CancellationToken.None);
            var asr = _settings.Current.Asr;
            client.Start(asr.Language, asr.VocabularyHint);
            if (Current == null) { await client.DisposeAsync(); return; }
            _speech = client;
            Log.Info("Extended notes: listening");
            StateChanged?.Invoke();
        }
        catch (Exception e)
        {
            Log.Warn("Extended notes: couldn't connect to the speech engine: " + e.Message);
            _nextConnect = DateTime.Now.AddSeconds(5);
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
        MaybeFormat(s);
        MaybeSummarize(s);
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

    async Task FormatAsync(NoteSession s)
    {
        if (_formatting) return;
        var take = s.BeginFormat();
        if (take == null) return;
        _formatting = true;
        var (heard, sent, seconds) = take.Value;
        string ai = sent;
        var failed = true;
        try
        {
            var r = await _llm.ProcessAsync(sent, FormatProfile);
            if (!r.SafetyNet && r.Text.Trim().Length > 0) { ai = r.Text; failed = false; }
            else Log.Info("Extended notes: the AI's formatting was rejected; keeping the text as heard");
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

    void MaybeSummarize(NoteSession s)
    {
        if (_summarizing || _formatting) return;
        if (s.Formatted.Length - Math.Min(s.SummarizedThrough, s.Formatted.Length) >= SummaryChars) _ = SummarizeAsync(s);
    }

    async Task SummarizeAsync(NoteSession s)
    {
        if (_summarizing) return;
        var fresh = s.BeginSummary();
        if (fresh == null) return;
        _summarizing = true;
        var basedOn = s.Summary;
        try
        {
            var input = "CURRENT SUMMARY:\n" + (basedOn.Trim().Length > 0 ? basedOn.Trim() : "(none yet)") + "\n\nNEW PART:\n" + fresh;
            var r = await _llm.ProcessAsync(input, SummaryProfile);
            if (r.SafetyNet || r.Text.Trim().Length == 0) { s.CancelSummary(); Log.Info("Extended notes: the summary update was rejected"); }
            else if (!s.EndSummary(r.Text, basedOn, this)) Log.Info("Extended notes: the summary was edited meanwhile; updating it next time");
        }
        catch (Exception e)
        {
            s.CancelSummary();
            Log.Warn("Extended notes: updating the summary failed: " + e.Message);
        }
        finally
        {
            _summarizing = false;
            _dirty = true;
        }
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
            var speech = _speech;
            _speech = null;
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
            await SummarizeAsync(s);
        }
        catch (Exception e) { Log.Error("Extended notes: finishing the session failed", e); }
        finally
        {
            s.Finished = true;
            _store.Save(s);
            Current = null;
            IsFinishing = false;
            _userPaused = false;
            Log.Info($"Extended notes: stopped {s.Id} after {TimeSpan.FromSeconds(s.Seconds):h\\:mm\\:ss}");
            StateChanged?.Invoke();
        }
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
        _speech = null;
        CloseWav();
        s.Seconds = Seconds;
        s.Finished = true;
        try { File.WriteAllText(Path.Combine(s.Folder, "session.json"), System.Text.Json.JsonSerializer.Serialize(s, JsonStore.Options)); }
        catch (Exception e) { Log.Warn("Extended notes: saving at exit failed: " + e.Message); }
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
