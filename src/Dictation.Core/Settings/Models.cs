using Dictation.Core.Infrastructure;

namespace Dictation.Core.Settings;

public enum InsertionMode { Auto, Typing, Clipboard }

/// <summary>System follows the Windows app theme; Light and Dark override it.</summary>
public enum AppTheme { System, Light, Dark }

/// <summary>Where the overlay sits on the screen. Declared row by row (top, middle, bottom), left to right.</summary>
public enum OverlayPosition { TopLeft, TopCenter, TopRight, MiddleLeft, Center, MiddleRight, BottomLeft, BottomCenter, BottomRight }

public sealed class AsrSettings
{
    public string Engine { get; set; } = "faster-whisper";
    /// <summary>faster-whisper model name, e.g. large-v3-turbo, distil-large-v3, medium.en, small.en.</summary>
    public string Model { get; set; } = "large-v3-turbo";
    /// <summary>auto | cuda | cpu</summary>
    public string Device { get; set; } = "auto";
    /// <summary>Empty = pick automatically (int8_float16 on GPU, int8 on CPU).</summary>
    public string ComputeType { get; set; } = "";
    /// <summary>ISO code such as "en"; empty = auto-detect.</summary>
    public string Language { get; set; } = "en";
    /// <summary>Optional hint of names/jargon to bias recognition, e.g. "Kubernetes, Dr. Nguyen".</summary>
    public string VocabularyHint { get; set; } = "";
    public int Port { get; set; } = 8765;
}

public sealed class LlmSettings
{
    /// <summary>Ollama-compatible endpoint. Must be a local address.</summary>
    public string Endpoint { get; set; } = "http://127.0.0.1:11435";
    public string DefaultModel { get; set; } = "qwen2.5:3b";
    public string KeepAlive { get; set; } = "30m";
    public bool AutoStartRuntime { get; set; } = true;
    public int TimeoutSeconds { get; set; } = 60;
}

public sealed class AppSettings
{
    public string Hotkey { get; set; } = "Ctrl+Space";
    public string CycleProfileHotkey { get; set; } = "Ctrl+Alt+P";
    /// <summary>Read the selected text aloud (or offer the clipboard when nothing is selected).</summary>
    public string SpeakHotkey { get; set; } = "Ctrl+Shift+Space";
    /// <summary>Kokoro voice id, e.g. af_heart.</summary>
    public string TtsVoice { get; set; } = "af_heart";
    /// <summary>Default reading speed, 0.5 to 2.0. The reader's +/− buttons change it for one reading only.</summary>
    public double TtsBaseSpeed { get; set; } = 1.0;
    public int TtsPort { get; set; } = 8766;
    public string? MicrophoneName { get; set; }
    public string? ActiveProfileId { get; set; }
    public string? DefaultProfileId { get; set; }
    public bool StartWithWindows { get; set; }
    public bool MinimizeToTray { get; set; } = true;
    public bool ShowOverlay { get; set; } = true;
    public AppTheme Theme { get; set; } = AppTheme.System;
    /// <summary>Opacity of the overlay's background (its text stays fully opaque). 0.6 to 1.</summary>
    public double OverlayOpacity { get; set; } = 0.88;
    public OverlayPosition OverlayPosition { get; set; } = OverlayPosition.BottomCenter;
    public InsertionMode Insertion { get; set; } = InsertionMode.Auto;
    /// <summary>Read a sentence or two around the cursor (locally, via UI Automation) to fix capitalization,
    /// trailing periods and spacing when inserting into the middle of existing text.</summary>
    public bool MatchSurroundingText { get; set; } = true;
    /// <summary>Type finished sentences into the app while still speaking (about every 5 seconds), then replace
    /// them with one final cleaned-up pass when dictation stops.</summary>
    public bool TypeWhileSpeaking { get; set; } = true;
    /// <summary>In Auto mode, text longer than this (or containing line breaks) is pasted instead of typed.</summary>
    public int TypingMaxChars { get; set; } = 400;
    public int MaxRecordingSeconds { get; set; } = 600;
    /// <summary>Keep the last sessions (raw + processed) in memory only; never written to disk.</summary>
    public bool KeepHistory { get; set; } = true;
    /// <summary>Ask GitHub for a newer release when the app starts. Off by default: the app makes no network calls unless asked.</summary>
    public bool CheckUpdatesOnStartup { get; set; }
    /// <summary>Per-application insertion override keyed by process name, e.g. "notepad": "Typing".</summary>
    public Dictionary<string, InsertionMode> AppOverrides { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public AsrSettings Asr { get; set; } = new();
    public LlmSettings Llm { get; set; } = new();
}

public sealed class Profile : Bindable
{
    string _id = Guid.NewGuid().ToString("N");
    string _name = "New Profile";
    string _description = "";
    string _prompt = "";
    string? _model;
    bool _autoProcess = true, _showPreview, _preserveParagraphs = true, _removeFillers = true, _rewriteWhole;
    double _maxChangeRatio = 0.5;

    public string Id { get => _id; set => Set(ref _id, value); }
    public string Name { get => _name; set => Set(ref _name, value); }
    public string Description { get => _description; set => Set(ref _description, value); }
    public string Prompt { get => _prompt; set => Set(ref _prompt, value); }
    /// <summary>Ollama model tag; null/empty = use the global default model.</summary>
    public string? Model { get => _model; set => Set(ref _model, value); }
    public bool AutoProcess { get => _autoProcess; set => Set(ref _autoProcess, value); }
    public bool ShowPreview { get => _showPreview; set => Set(ref _showPreview, value); }
    public bool PreserveParagraphs { get => _preserveParagraphs; set => Set(ref _preserveParagraphs, value); }
    public bool RemoveFillers { get => _removeFillers; set => Set(ref _removeFillers, value); }
    /// <summary>Give the AI the whole dictation in one piece once the user stops, so the instructions can reshape it
    /// (into an email, a list, ...). Off: long dictation is edited a few sentences at a time, which keeps small models
    /// faithful. While speaking, a rewriting profile types the words as spoken; the rewrite replaces them at the end.</summary>
    public bool RewriteWhole { get => _rewriteWhole; set => Set(ref _rewriteWhole, value); }
    bool _isActive, _isDefault;
    /// <summary>UI-only flags (not persisted).</summary>
    [System.Text.Json.Serialization.JsonIgnore] public bool IsActive { get => _isActive; set => Set(ref _isActive, value); }
    [System.Text.Json.Serialization.JsonIgnore] public bool IsDefault { get => _isDefault; set => Set(ref _isDefault, value); }
    /// <summary>Safety net: if the model's output differs in length from the input by more than this
    /// fraction, it is rejected and the raw transcript is used. 0.5 = +/-50%.</summary>
    public double MaxChangeRatio { get => _maxChangeRatio; set => Set(ref _maxChangeRatio, value); }
}
