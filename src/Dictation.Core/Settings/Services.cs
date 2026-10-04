using System.Collections.ObjectModel;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Settings;

public sealed class SettingsService
{
    readonly string _path = Path.Combine(AppPaths.DataDir, "settings.json");
    public AppSettings Current { get; private set; }
    public event Action? Changed;

    public SettingsService()
    {
        Current = JsonStore.Load<AppSettings>(_path) ?? new AppSettings();
        Current.AppOverrides = new Dictionary<string, InsertionMode>(Current.AppOverrides, StringComparer.OrdinalIgnoreCase);
        EnforceLocalEndpoint();
    }

    /// <summary>Privacy guard: the LLM endpoint must be loopback, otherwise transcripts could leave the machine.</summary>
    void EnforceLocalEndpoint()
    {
        if (Uri.TryCreate(Current.Llm.Endpoint, UriKind.Absolute, out var u) && u.IsLoopback) return;
        Log.Warn($"LLM endpoint '{Current.Llm.Endpoint}' is not local; resetting to default.");
        Current.Llm.Endpoint = new LlmSettings().Endpoint;
    }

    public void Save()
    {
        EnforceLocalEndpoint();
        try { JsonStore.Save(_path, Current); }
        catch (Exception e) { Log.Error("Saving settings failed", e); }
        Changed?.Invoke();
    }
}

public sealed class ProfileService
{
    readonly string _path = Path.Combine(AppPaths.DataDir, "profiles.json");
    readonly SettingsService _settings;
    public ObservableCollection<Profile> Profiles { get; } = new();
    public event Action? ActiveChanged;

    public ProfileService(SettingsService settings)
    {
        _settings = settings;
        var loaded = JsonStore.Load<List<Profile>>(_path);
        foreach (var p in loaded is { Count: > 0 } ? loaded : BuiltInProfiles.Create()) Profiles.Add(p);
        var s = settings.Current;
        // Built-ins added in later versions (with a fixed id) show up once for existing users, too.
        var changed = loaded is not { Count: > 0 };
        foreach (var p in BuiltInProfiles.Create().Where(p => BuiltInProfiles.FixedIds.Contains(p.Id)))
        {
            if (s.BuiltInProfilesAdded.Contains(p.Id)) continue;
            if (Find(p.Id) == null) Profiles.Add(p);
            s.BuiltInProfilesAdded.Add(p.Id);
            changed = true;
        }
        if (changed) { Save(); settings.Save(); }
        s.DefaultProfileId = Find(s.DefaultProfileId)?.Id ?? Profiles[0].Id;
        s.ActiveProfileId = Find(s.DefaultProfileId)?.Id ?? s.DefaultProfileId; // active starts as the default
        RefreshFlags();
    }

    public void RefreshFlags()
    {
        foreach (var p in Profiles)
        {
            p.IsActive = p.Id == _settings.Current.ActiveProfileId;
            p.IsDefault = p.Id == _settings.Current.DefaultProfileId;
        }
    }

    public Profile? Find(string? id) => Profiles.FirstOrDefault(p => p.Id == id);
    public Profile Active => Find(_settings.Current.ActiveProfileId) ?? Profiles[0];
    public Profile Default => Find(_settings.Current.DefaultProfileId) ?? Profiles[0];

    public void SetActive(Profile p)
    {
        _settings.Current.ActiveProfileId = p.Id;
        _settings.Save();
        RefreshFlags();
        ActiveChanged?.Invoke();
    }

    public void SetDefault(Profile p)
    {
        _settings.Current.DefaultProfileId = p.Id;
        _settings.Save();
        RefreshFlags();
    }

    public void CycleActive()
    {
        var i = Profiles.IndexOf(Active);
        SetActive(Profiles[(i + 1) % Profiles.Count]);
    }

    public Profile Create(string name = "New Profile")
    {
        var p = new Profile
        {
            Name = name,
            Description = "Custom editing profile.",
            Prompt = BuiltInProfiles.CustomPrompt,
        };
        Profiles.Add(p);
        Save();
        return p;
    }

    public bool Delete(Profile p)
    {
        if (Profiles.Count <= 1) return false; // always keep at least one
        var wasActive = p.Id == _settings.Current.ActiveProfileId;
        Profiles.Remove(p);
        if (_settings.Current.DefaultProfileId == p.Id) _settings.Current.DefaultProfileId = Profiles[0].Id;
        if (wasActive) _settings.Current.ActiveProfileId = _settings.Current.DefaultProfileId;
        _settings.Save();
        Save();
        RefreshFlags();
        if (wasActive) ActiveChanged?.Invoke();
        return true;
    }

    public void Save()
    {
        try { JsonStore.Save(_path, Profiles.ToList()); }
        catch (Exception e) { Log.Error("Saving profiles failed", e); }
    }
}

public static class BuiltInProfiles
{
    public const string RawId = "builtin-raw";
    /// <summary>Built-ins with a fixed id; older ones got random ids when they were created.</summary>
    public static readonly IReadOnlySet<string> FixedIds = new HashSet<string> { RawId };

    public const string CustomPrompt =
        "You are a dictation editor. Clean up this speech transcript: remove filler words and false starts, " +
        "and fix punctuation and capitalization, while keeping the speaker's meaning and wording.\n" +
        "Do not summarize or add information.\nReturn only the processed text.";

    public static List<Profile> Create() => new()
    {
        new Profile
        {
            Name = "Light Cleanup",
            Description = "Minimal cleanup of natural speech. Keeps your exact wording and voice.",
            Prompt = """
                You are a conservative dictation editor. Clean up this speech transcript while preserving the speaker's exact meaning, wording, tone, and intent.
                Remove non-meaningful filler words such as um and uh.
                Remove accidental repeated words and obvious abandoned fragments when doing so does not change the meaning.
                Correct spelling, capitalization, punctuation, and clear grammatical errors.
                Preserve the speaker's vocabulary, sentence structure, and natural voice wherever possible.
                Preserve deliberate repetition, emphasis, and meaningful self-corrections.
                Do not summarize, add details, invent information, or rewrite for style.
                If a phrase is ambiguous, leave it unchanged rather than guessing.
                Return only the cleaned transcript.
                """,
            MaxChangeRatio = 0.4,
        },
        new Profile
        {
            Name = "Grammar & Clarity",
            Description = "Fixes grammar and awkward constructions more firmly, keeping your meaning and voice.",
            Prompt = """
                You are a careful copy editor working on a dictated transcript. Correct grammar, agreement, tense, word choice errors, and awkward or run-on sentence construction so the text is clear and correct.
                Remove filler words, false starts, accidental repetitions, and abandoned fragments.
                Fix spelling, capitalization, and punctuation. Split run-on sentences where needed.
                Keep the speaker's meaning, vocabulary, and tone. Keep every fact, name, number, and opinion exactly as stated.
                Do not summarize, add information, or change what is being said. You may lightly reorder words within a sentence only when needed for clarity.
                If something is ambiguous, leave it as spoken rather than guessing.
                Return only the edited text.
                """,
            MaxChangeRatio = 0.5,
        },
        new Profile
        {
            Name = "Natural Phrasing",
            Description = "Makes spoken language read like written language while keeping the meaning and tone.",
            Prompt = """
                You are editing a dictated transcript so that it reads naturally as written text, as if the speaker had typed it carefully.
                Remove filler words, false starts, repetitions, and verbal tics. Convert spoken constructions into natural written phrasing, and tidy sentence flow and punctuation.
                Preserve the speaker's meaning, intent, tone, and level of formality. Keep all facts, names, numbers, and opinions exactly as stated.
                Never summarize, never add information that was not said, and never drop meaningful content.
                If something is ambiguous, keep it as spoken rather than guessing.
                Return only the rewritten text.
                """,
            MaxChangeRatio = 0.6,
        },
        new Profile
        {
            Name = "Custom",
            Description = "Write your own instructions.",
            Prompt = CustomPrompt,
            MaxChangeRatio = 0.6,
        },
        new Profile
        {
            Id = RawId,
            Name = "Raw",
            Description = "Exactly what the speech recognizer heard. No AI: nothing is reworded, fast and private.",
            Prompt = "",
            AutoProcess = false,
        },
    };
}

