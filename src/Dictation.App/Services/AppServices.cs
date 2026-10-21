using System.Windows;
using Dictation.Core.Audio;
using Dictation.Core.Infrastructure;
using Dictation.Core.Insertion;
using Dictation.Core.Notes;
using Dictation.Core.Session;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Dictation.Core.Text;
using Microsoft.Win32;

namespace Dictation.App.Services;

/// <summary>Live engine status shown in the main window footer.</summary>
public sealed class AppStatus : Bindable
{
    string _speech = "Speech: starting…", _ai = "AI: starting…";
    bool _speechOk, _aiOk;
    public string Speech { get => _speech; set => Set(ref _speech, value); }
    public string Ai { get => _ai; set => Set(ref _ai, value); }
    public bool SpeechOk { get => _speechOk; set => Set(ref _speechOk, value); }
    public bool AiOk { get => _aiOk; set => Set(ref _aiOk, value); }
}

/// <summary>Hand-wired composition root. Every component is behind an interface and replaceable here.</summary>
public sealed class AppServices
{
    public SettingsService Settings { get; } = new();
    public ProfileService Profiles { get; }
    public IAudioCapture Mic { get; } = Environment.GetEnvironmentVariable("DICTATION_FAKE_AUDIO") is { Length: > 0 } wav
        ? new FileAudioCapture(wav)   // diagnostics only: feed a WAV file instead of the microphone
        : new MicCapture();
    public ISpeechRecognizer Speech { get; }
    public OllamaHost OllamaHost { get; }
    public ITextProcessor Llm { get; }
    public TextInserter Inserter { get; }
    public DictationController Controller { get; }
    /// <summary>Recent dictations, kept in data\history.</summary>
    public HistoryStore History { get; }
    /// <summary>History › Run again: a kept dictation transcribed and cleaned up afresh from its recording.</summary>
    public HistoryRerun Rerun { get; }
    /// <summary>Daily counts for the dashboard (no text), in data\usage.json.</summary>
    public UsageStore Usage { get; }
    /// <summary>Word, phrase and correction counts for Analytics (no sentences), in data\words.json.</summary>
    public WordTally Words { get; }
    /// <summary>Extended Notes: the sessions on disk, and the one recording now.</summary>
    public NotesStore NotesStore { get; }
    public NotesRecorder Notes { get; }
    /// <summary>Read aloud's voice (Kokoro); its process starts on first use.</summary>
    public KokoroSpeech Tts { get; }
    /// <summary>Every Read aloud voice: Kokoro's and the ones installed with Windows.</summary>
    public SpeechVoices Voices { get; }
    public AppStatus Status { get; } = new();

    public AppServices()
    {
        Profiles = new ProfileService(Settings);
        Speech = new SidecarSpeechRecognizer(Settings);
        OllamaHost = new OllamaHost(Settings);
        Llm = new OllamaTextProcessor(Settings, OllamaHost);
        Inserter = new TextInserter(Settings);
        History = new HistoryStore(Settings);
        Usage = new UsageStore(UsageStore.DefaultPath, History.Entries);
        Words = new WordTally(WordTally.DefaultPath, History.Entries, Settings);
        Controller = new DictationController(Mic, Speech, Llm, Inserter, Settings, Profiles, History, Usage, Words);
        Tts = new KokoroSpeech(Settings);
        NotesStore = new NotesStore();
        // Notes use the speech model already loaded (no reload), else the active profile's.
        Notes = new NotesRecorder(Settings, Speech, Llm, NotesStore,
            () => Speech.LoadedModel ?? SpeechModels.For(Profiles.Active, Settings.Current.Asr));
        Voices = new SpeechVoices(Tts);
        // The profile's speech model is loaded for a rerun only when nothing else is using the one loaded now.
        Rerun = new HistoryRerun(Settings, Speech, Llm, Profiles, History,
            () => !Notes.NeedsModels && Controller.State == DictationState.Idle);

        var d = Application.Current.Dispatcher;
        Speech.StatusChanged += (s, ok) => d.BeginInvoke(() => { Status.Speech = "Speech: " + s; Status.SpeechOk = ok; });
        Llm.StatusChanged += (s, ok) => d.BeginInvoke(() => { Status.Ai = "AI: " + s; Status.AiOk = ok; });
    }
}

public static class Autostart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "LocalDictation";

    public static void Apply(bool enabled)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key, true);
            if (k == null) return;
            if (enabled) k.SetValue(Name, $"\"{Environment.ProcessPath}\" --minimized");
            else k.DeleteValue(Name, false);
        }
        catch (Exception e) { Log.Warn("Autostart change failed: " + e.Message); }
    }
}
