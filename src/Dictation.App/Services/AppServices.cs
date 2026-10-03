using System.Windows;
using Dictation.Core.Audio;
using Dictation.Core.Infrastructure;
using Dictation.Core.Insertion;
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
    /// <summary>Read aloud's voice (Kokoro); its process starts on first use.</summary>
    public KokoroSpeech Tts { get; }
    public AppStatus Status { get; } = new();

    public AppServices()
    {
        Profiles = new ProfileService(Settings);
        Speech = new SidecarSpeechRecognizer(Settings);
        OllamaHost = new OllamaHost(Settings);
        Llm = new OllamaTextProcessor(Settings, OllamaHost);
        Inserter = new TextInserter(Settings);
        Controller = new DictationController(Mic, Speech, Llm, Inserter, Settings, Profiles);
        Tts = new KokoroSpeech(Settings);

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
