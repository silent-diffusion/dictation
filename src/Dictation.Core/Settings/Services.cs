using System.Collections.ObjectModel;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Settings;

public sealed class SettingsService
{
    readonly string _path;
    public AppSettings Current { get; private set; }
    public event Action? Changed;

    public SettingsService() : this(Path.Combine(AppPaths.DataDir, "settings.json")) { }

    internal SettingsService(string path)
    {
        _path = path;
        // New settings wait for setup to choose models for the hardware (other services may save them before it runs).
        Current = JsonStore.Load<AppSettings>(_path) ?? new AppSettings { ModelsChosen = false };
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
        var fresh = loaded is not { Count: > 0 };
        foreach (var p in fresh ? BuiltInProfiles.Create() : loaded!) Profiles.Add(p);
        var s = settings.Current;
        // A new install starts with Grammar & Clarity as the default (and active) profile.
        if (fresh) s.DefaultProfileId = s.ActiveProfileId = Profiles.FirstOrDefault(p => p.Name == BuiltInProfiles.DefaultName)?.Id;
        // Built-ins added in later versions (with a fixed id) show up once for existing users, too.
        var changed = fresh;
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
    /// <summary>The profile a new install starts with.</summary>
    public const string DefaultName = "Grammar & Clarity";
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
                Do not summarize, add details, invent information, or rewrite for style.
                Never use "—" or "..."
                If a phrase is ambiguous, leave it unchanged rather than guessing.
                Return only the cleaned transcript.
                """,
            MaxChangeRatio = 0.4,
        },
        new Profile
        {
            Name = DefaultName,
            Description = "Fixes grammar and awkward constructions more firmly, keeping your meaning and voice.",
            Prompt = """
                You are a careful copy editor working on a dictated transcript. Correct grammar, agreement, tense, word choice errors, and run-on sentences. Remove filler words, false starts, accidental repetitions, and abandoned fragments. Fix spelling, capitalization, and punctuation. Split run-on sentences where needed.

                Keep the speaker's meaning, vocabulary, and tone. Keep every fact, name, number, and opinion exactly as stated.

                Do not use "—"
                Do not use any ellipses "..."
                Do not summarize, add information, or take away information.

                Make the text clear and correct.

                Return only the edited text.
                """,
            MaxChangeRatio = 0.5,
        },
        new Profile
        {
            Name = "AI Parsing Formatter",
            Description = "Turns a spoken stream of thought into clear, organized instructions for an AI assistant.",
            Prompt = """
                You are an editor who turns a spoken stream of thought into clear, well-organized instructions for an AI assistant (for example a coding assistant or chat assistant). You do NOT carry out the instructions yourself; you only rewrite them.

                Rewrite the transcript as a direct, actionable request:
                - Start with one or two sentences stating the overall goal.
                - Then list the specific changes or actions as a numbered list, in a logical order. Group related points together and merge duplicates.
                - When the speaker corrects themselves ("no wait", "actually", "scratch that"), keep only the final version of what they want.
                - Put constraints, preferences, and things to avoid in a short "Constraints:" list after the actions, if there are any.
                - If the speaker is unsure about something or asks a question, keep it as a clearly marked question rather than turning it into an instruction.
                - Write in plain, direct, imperative language ("Add…", "Change…", "Remove…"). Remove filler words, rambling, thinking out loud, and repetition.

                Strict rules:
                - Preserve every technical detail exactly as spoken: file names, function names, settings, values, numbers, error messages, and product names.
                - Never add requirements, steps, or assumptions the speaker did not express, and never drop one they did.
                - Do not answer the request, write code, or comment on it.
                - If something is ambiguous, keep the speaker's wording rather than guessing.

                Return only the rewritten instructions.
                """,
            MaxChangeRatio = 0.6,
        },
        new Profile
        {
            Name = "Email Formatter",
            Description = "Turns dictation into a clear, professional email, shown for a look before it goes in.",
            Prompt = """
                You are an editor who turns dictated speech into a clear, professional business email.

                Rewrite the transcript as a well-structured email in business-professional language:
                - Start with a greeting. If the speaker names the recipient, use their name (for example "Hi Sarah,"); otherwise use "Hello,".
                - Open with the main point or purpose of the email in the first sentence or two.
                - Organize the rest into short, focused paragraphs. Use a bulleted list only when the speaker lists several items, steps, or dates.
                - Use polite, confident, concise wording. Replace casual or slang phrasing with professional equivalents, and remove filler words, false starts, repetition, and rambling.
                - If the speaker asks for something, state the request clearly, including any deadline they mention.
                - End with a brief, appropriate closing line (for example "Please let me know if you have any questions.")

                Strict rules:
                - Keep every fact, name, number, date, time, and commitment exactly as the speaker stated it.
                - Never invent details, names, promises, or information that was not said.
                - Do not add a subject line, a signature, or placeholders such as [Your Name].
                - Do not invent new information. All of the references and questions should come from the transcribed text.
                - If something is unclear, keep the speaker's wording rather than guessing.
                - Always start with an introduction greeting line, and then every idea should start its own line.

                Return only the email text.
                """,
            ShowPreview = true,
            RewriteWhole = true,
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

