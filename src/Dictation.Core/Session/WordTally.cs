using System.Text.RegularExpressions;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Text;

namespace Dictation.Core.Session;

/// <summary>One day of the word tally: counts only, never sentences.</summary>
public sealed class TallyDay
{
    public DateTime Day { get; set; }
    /// <summary>Words that went in (common words left out), lower case.</summary>
    public Dictionary<string, int> Words { get; set; } = new();
    /// <summary>Three- and four-word phrases that went in, lower case.</summary>
    public Dictionary<string, int> Phrases { get; set; } = new();
    /// <summary>"heard → written" pairs: what the recognizer heard and what the AI wrote instead.</summary>
    public Dictionary<string, int> Corrections { get; set; } = new();
    /// <summary>Filler words the AI took out (um, uh, like…).</summary>
    public Dictionary<string, int> Fillers { get; set; } = new();
    /// <summary>Dictations per hour of the day (0–23).</summary>
    public int[] Hours { get; set; } = new int[24];
    /// <summary>Per profile name: how it was used and how much it edited.</summary>
    public Dictionary<string, ProfileTally> Profiles { get; set; } = new();
    /// <summary>The same counts per app ("chrome") and per browser site ("chrome › Gmail", see <see cref="WordTally.AppKey"/>),
    /// so Analytics can show one app's words. Counted from 5.10.0 on (and from what History still had then).</summary>
    public Dictionary<string, TallyPart> Apps { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>One app's (or site's) share of a day of the word tally.</summary>
public sealed class TallyPart
{
    public int Dictations { get; set; }
    public Dictionary<string, int> Words { get; set; } = new();
    public Dictionary<string, int> Phrases { get; set; } = new();
    public Dictionary<string, int> Corrections { get; set; } = new();
    public Dictionary<string, int> Fillers { get; set; } = new();
    public int[] Hours { get; set; } = new int[24];
}

public sealed class ProfileTally
{
    public int Dictations { get; set; }
    /// <summary>Dictations the AI worked on, and how many kept its edit (not rejected by the safety net).</summary>
    public int AiEdited { get; set; }
    public int AiKept { get; set; }
    /// <summary>Words heard, and how many of them the AI changed (removed or replaced) or added.</summary>
    public int WordsHeard { get; set; }
    public int WordsChanged { get; set; }
    public double FinishSeconds { get; set; }
    public int FinishCount { get; set; }
}

/// <summary>What one dictation adds to the tally; worked out without touching any store, so it can be tested.</summary>
public sealed record TallyItem(
    IReadOnlyList<string> Words,
    IReadOnlyList<string> Phrases,
    IReadOnlyList<string> Corrections,
    IReadOnlyList<string> Fillers,
    int WordsHeard,
    int WordsChanged);

/// <summary>
/// The Analytics section's word tally, in data\words.json: per day, the words and phrases you dictate, the words the
/// AI corrects, the fillers it removes, when you dictate and how each profile edits. Counts only: no sentence is ever
/// kept, so a dictation can't be pieced back together from it. On by default (Settings › History); updated in the
/// background after every dictation; seeded once from History so it doesn't start empty.
/// </summary>
public sealed class WordTally
{
    /// <summary>About thirteen months; older days are dropped.</summary>
    public const int KeepDays = 400;
    public const string Arrow = " → ";

    public sealed class FileData
    {
        /// <summary>2: days have <see cref="TallyDay.Apps"/>.</summary>
        public int Version { get; set; } = 1;
        public List<TallyDay> Days { get; set; } = new();
    }

    readonly string? _path;
    readonly SettingsService? _settings;
    readonly object _lock = new();
    readonly FileData _data;

    public static string DefaultPath => Path.Combine(AppPaths.DataDir, "words.json");

    /// <param name="path">Where to keep the tally; null keeps it in memory only (tests).</param>
    /// <param name="seed">Used once, when there is no file yet: the dictations already in History.</param>
    /// <param name="settings">For the on/off switch; null counts always (tests).</param>
    public WordTally(string? path, IEnumerable<HistoryEntry>? seed = null, SettingsService? settings = null)
    {
        _path = path;
        _settings = settings;
        var loaded = path == null ? null : JsonStore.Load<FileData>(path);
        _data = loaded ?? new FileData();
        if (loaded == null && seed != null && Enabled)
        {
            foreach (var e in seed.OrderBy(e => e.Time)) Count(e);
            _data.Version = 2;
            Compact();
            Save();
        }
        else if (loaded != null && _data.Version < 2)
        {
            // Per-app counts are new: fill them in from the dictations History still has (the rest stay in the totals only).
            if (Enabled)
                foreach (var e in (seed ?? Enumerable.Empty<HistoryEntry>()).OrderBy(e => e.Time))
                    if (_data.Days.FirstOrDefault(x => x.Day == e.Time.Date) is { } d) CountApps(d, e, Analyze(e.Transcript, e.AiOutput, e.Final));
            _data.Version = 2;
            Compact();
            Save();
        }
    }

    /// <summary>The key a dictation's app (and, in a browser, its site) is counted under: "chrome", "chrome › Gmail".</summary>
    public static string AppKey(string app, string? site = null) => site == null ? app : app + " › " + site;

    /// <summary>The tally of one app or site (<see cref="AppKey"/>), as days of its own (without profiles), so the
    /// figures below work on it as on the whole.</summary>
    public static List<TallyDay> ForApp(IEnumerable<TallyDay> days, string key) =>
        days.Where(d => d.Apps.ContainsKey(key)).Select(d =>
        {
            var p = d.Apps[key];
            return new TallyDay { Day = d.Day, Words = p.Words, Phrases = p.Phrases, Corrections = p.Corrections, Fillers = p.Fillers, Hours = p.Hours };
        }).ToList();

    bool Enabled => _settings?.Current.KeepWordTally ?? true;

    /// <summary>Raised (on a background thread) after a dictation was counted or the tally was reset, so Analytics can
    /// show it right away.</summary>
    public event Action? Changed;

    /// <summary>Count a finished dictation, off the UI thread (it diffs and writes a file).</summary>
    public void Record(HistoryEntry entry)
    {
        if (!Enabled) return;
        _ = Task.Run(() =>
        {
            try
            {
                lock (_lock)
                {
                    Count(entry);
                    Compact();
                    Save();
                }
                Changed?.Invoke();
            }
            catch (Exception e) { Log.Warn("Updating the word tally failed: " + e.Message); }
        });
    }

    /// <summary>Forget everything (Settings › History).</summary>
    public void Clear()
    {
        lock (_lock)
        {
            _data.Days.Clear();
            Save();
        }
        Changed?.Invoke();
    }

    /// <summary>A copy of the days from <paramref name="from"/> on (all of them when null), oldest first.</summary>
    public IReadOnlyList<TallyDay> Days(DateTime? from = null)
    {
        lock (_lock) return _data.Days.Where(d => from == null || d.Day >= from.Value.Date).ToList();
    }

    void Count(HistoryEntry e)
    {
        var item = Analyze(e.Transcript, e.AiOutput, e.Final);
        var d = DayOf(e.Time);
        foreach (var w in item.Words) Add(d.Words, w);
        foreach (var p in item.Phrases) Add(d.Phrases, p);
        foreach (var c in item.Corrections) Add(d.Corrections, c);
        foreach (var f in item.Fillers) Add(d.Fillers, f);
        d.Hours[Math.Clamp(e.Time.Hour, 0, 23)]++;

        var name = string.IsNullOrWhiteSpace(e.Profile) ? "Unknown profile" : e.Profile;
        if (!d.Profiles.TryGetValue(name, out var p0)) d.Profiles[name] = p0 = new ProfileTally();
        p0.Dictations++;
        if (e.AiOutput != null || e.SafetyNet)
        {
            p0.AiEdited++;
            if (e.AiOutput != null && !e.SafetyNet) p0.AiKept++;
        }
        p0.WordsHeard += item.WordsHeard;
        p0.WordsChanged += item.WordsChanged;
        if (e.FinishSeconds > 0) { p0.FinishSeconds += e.FinishSeconds; p0.FinishCount++; }
        CountApps(d, e, item);
    }

    /// <summary>The dictation's words again, under its app, and under its site when it went into a browser.</summary>
    static void CountApps(TallyDay d, HistoryEntry e, TallyItem item)
    {
        var keys = new List<string> { AppKey(e.AppName) };
        if (WebSites.Site(e.App, e.WindowTitle) is { } site) keys.Add(AppKey(e.AppName, site));
        foreach (var key in keys)
        {
            if (!d.Apps.TryGetValue(key, out var p)) d.Apps[key] = p = new TallyPart();
            p.Dictations++;
            foreach (var w in item.Words) Add(p.Words, w);
            foreach (var x in item.Phrases) Add(p.Phrases, x);
            foreach (var c in item.Corrections) Add(p.Corrections, c);
            foreach (var f in item.Fillers) Add(p.Fillers, f);
            if (p.Hours.Length < 24) p.Hours = new int[24];
            p.Hours[Math.Clamp(e.Time.Hour, 0, 23)]++;
        }
    }

    static void Add(Dictionary<string, int> d, string key) => d[key] = d.GetValueOrDefault(key) + 1;

    TallyDay DayOf(DateTime time)
    {
        var day = time.Date;
        var d = _data.Days.FirstOrDefault(x => x.Day == day);
        if (d != null) return d;
        d = new TallyDay { Day = day };
        _data.Days.Add(d);
        _data.Days.Sort((a, b) => a.Day.CompareTo(b.Day));
        return d;
    }

    /// <summary>Keep the file small: drop old days, and from days before today the phrases said only once (most
    /// three-word runs never repeat, and only repeats are worth showing).</summary>
    void Compact()
    {
        var cutoff = DateTime.Today.AddDays(-KeepDays);
        _data.Days.RemoveAll(x => x.Day < cutoff);
        foreach (var d in _data.Days.Where(x => x.Day < DateTime.Today))
        {
            foreach (var once in d.Phrases.Where(kv => kv.Value < 2).Select(kv => kv.Key).ToList())
                d.Phrases.Remove(once);
            foreach (var p in d.Apps.Values)
                foreach (var once in p.Phrases.Where(kv => kv.Value < 2).Select(kv => kv.Key).ToList())
                    p.Phrases.Remove(once);
        }
    }

    void Save()
    {
        if (_path == null) return;
        try { JsonStore.Save(_path, _data); }
        catch (Exception e) { Log.Warn("Saving the word tally failed: " + e.Message); }
    }

    // ===== working out what a dictation adds =====

    /// <summary>Common words that would crowd every list; left out of "most used words".</summary>
    internal static readonly HashSet<string> CommonWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "an", "the", "and", "but", "or", "nor", "so", "yet", "for", "if", "then", "than", "that", "this", "these",
        "those", "which", "who", "whom", "whose", "what", "when", "where", "why", "how", "as", "at", "by", "from", "in",
        "into", "of", "on", "onto", "to", "with", "without", "about", "after", "before", "over", "under", "up", "down",
        "out", "off", "through", "it", "its", "it's", "i", "i'm", "i've", "i'll", "i'd", "me", "my", "we", "we're",
        "our", "us", "you", "you're", "your", "he", "she", "him", "her", "his", "they", "them", "their", "there",
        "here", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "don't", "doesn't",
        "didn't", "have", "has", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "not", "no", "yes", "also", "just", "very", "too", "all", "any", "some", "each", "every", "both", "more",
        "most", "much", "many", "other", "such", "only", "even", "still", "again", "now", "well", "okay", "ok",
        "like", "really", "get", "got", "go", "going", "let", "let's", "that's", "there's", "what's", "can't",
        "won't", "isn't", "aren't", "wasn't", "one", "two", "because", "while", "though", "into", "per", "via",
    };

    /// <summary>Words the AI removes as fillers; counted when they disappear in its edit.</summary>
    internal static readonly HashSet<string> FillerWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "um", "umm", "uh", "uhh", "er", "erm", "ah", "eh", "hmm", "mm", "like", "basically", "literally", "actually",
        "so", "okay", "well",
    };

    static readonly Regex WordRx = new(@"[\p{L}\p{N}]+(?:['’][\p{L}]+)*", RegexOptions.Compiled);

    /// <summary>The words of a text, lower case, apostrophes straightened, punctuation dropped.</summary>
    internal static List<string> Tokens(string? text) =>
        text == null ? new List<string>() : WordRx.Matches(text).Select(m => m.Value.Replace('’', '\'').ToLowerInvariant()).ToList();

    /// <summary>What one dictation adds: its words and phrases (from the text that went in), and from the AI's edit
    /// of what was heard, the corrections and the fillers taken out.</summary>
    public static TallyItem Analyze(string transcript, string? aiOutput, string final)
    {
        var text = string.IsNullOrWhiteSpace(final) ? transcript : final;
        var tokens = Tokens(text);
        var words = tokens.Where(t => t.Length >= 2 && !CommonWords.Contains(t) && !t.All(char.IsDigit)).ToList();

        var phrases = new List<string>();
        foreach (var sentence in Regex.Split(text ?? "", @"(?<=[.!?;:])\s+|\n"))
        {
            var s = Tokens(sentence);
            for (var n = 3; n <= 4; n++)
                for (var i = 0; i + n <= s.Count; i++)
                {
                    var run = s.GetRange(i, n);
                    // At least one word that carries meaning: "and it was" isn't a phrase anyone reaches for.
                    if (run.All(CommonWords.Contains)) continue;
                    phrases.Add(string.Join(" ", run));
                }
        }

        var heard = Tokens(transcript).Count;
        var corrections = new List<string>();
        var fillers = new List<string>();
        var changed = 0;
        if (!string.IsNullOrWhiteSpace(aiOutput))
        {
            var diff = WordDiff.Compute(transcript, aiOutput);
            for (var i = 0; i < diff.Count;)
            {
                if (diff[i].Kind == DiffKind.Same) { i++; continue; }
                var removed = new List<string>();
                var added = new List<string>();
                for (; i < diff.Count && diff[i].Kind != DiffKind.Same; i++)
                    (diff[i].Kind == DiffKind.Removed ? removed : added).Add(diff[i].Word);
                changed += Math.Max(removed.Count, added.Count);

                var removedWords = removed.SelectMany(Tokens).ToList();
                foreach (var w in removedWords.Where(FillerWords.Contains)) fillers.Add(w);
                for (var k = 0; k + 1 < removedWords.Count; k++)
                    if (removedWords[k] == "you" && removedWords[k + 1] == "know") fillers.Add("you know");

                var pair = Correction(removed, added);
                if (pair != null) corrections.Add(pair);
            }
        }
        return new TallyItem(words, phrases, corrections, fillers, heard, changed);
    }

    /// <summary>"heard → written" when a short run of heard words was replaced by a short run of other words that
    /// carry meaning (a name, a product, a term); null for grammar fixes, fillers and punctuation.</summary>
    internal static string? Correction(IReadOnlyList<string> removed, IReadOnlyList<string> added)
    {
        if (removed.Count is < 1 or > 3 || added.Count is < 1 or > 3) return null;
        var heard = Clean(string.Join(" ", removed));
        var written = Clean(string.Join(" ", added));
        if (heard.Length == 0 || written.Length == 0) return null;
        var heardWords = Tokens(heard);
        var writtenWords = Tokens(written);
        if (heardWords.All(FillerWords.Contains)) return null;
        if (!writtenWords.Any(w => w.Length >= 3 && !CommonWords.Contains(w))) return null;
        // Only capitals or punctuation changed: not a correction anyone needs to teach.
        if (string.Join(" ", heardWords) == string.Join(" ", writtenWords)) return null;
        return heard.ToLowerInvariant() + Arrow + written;
    }

    static string Clean(string s) => s.Trim().Trim('.', ',', ';', ':', '!', '?', '"', '\'', '“', '”', '‘', '’', '(', ')', '…', '-', '—').Trim();

    // ===== figures for the Analytics page =====

    public static IReadOnlyList<(string Key, int Count)> Top(IEnumerable<TallyDay> days, Func<TallyDay, Dictionary<string, int>> pick, int count)
    {
        var sum = new Dictionary<string, int>();
        foreach (var d in days) foreach (var (k, v) in pick(d)) sum[k] = sum.GetValueOrDefault(k) + v;
        return sum.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(count).Select(kv => (kv.Key, kv.Value)).ToList();
    }

    /// <summary>The most repeated phrases, without one that is only part of a longer phrase shown above it ("go ahead"
    /// under "go ahead and").</summary>
    public static IReadOnlyList<(string Phrase, int Count)> TopPhrases(IEnumerable<TallyDay> days, int count)
    {
        var picked = new List<(string, int)>();
        foreach (var (p, n) in Top(days, d => d.Phrases, count * 6))
        {
            if (n < 2) break;
            if (picked.Any(x => (" " + x.Item1 + " ").Contains(" " + p + " ") || (" " + p + " ").Contains(" " + x.Item1 + " "))) continue;
            picked.Add((p, n));
            if (picked.Count == count) break;
        }
        return picked;
    }

    /// <summary>Dictations by weekday (Monday first) and hour.</summary>
    public static int[,] WeekHours(IEnumerable<TallyDay> days)
    {
        var grid = new int[7, 24];
        foreach (var d in days)
        {
            var row = ((int)d.Day.DayOfWeek + 6) % 7;
            for (var h = 0; h < 24 && h < d.Hours.Length; h++) grid[row, h] += d.Hours[h];
        }
        return grid;
    }

    public static IReadOnlyList<(string Profile, ProfileTally Total)> ByProfile(IEnumerable<TallyDay> days)
    {
        var sum = new Dictionary<string, ProfileTally>();
        foreach (var d in days)
            foreach (var (name, p) in d.Profiles)
            {
                if (!sum.TryGetValue(name, out var t)) sum[name] = t = new ProfileTally();
                t.Dictations += p.Dictations; t.AiEdited += p.AiEdited; t.AiKept += p.AiKept;
                t.WordsHeard += p.WordsHeard; t.WordsChanged += p.WordsChanged;
                t.FinishSeconds += p.FinishSeconds; t.FinishCount += p.FinishCount;
            }
        return sum.OrderByDescending(kv => kv.Value.Dictations).Select(kv => (kv.Key, kv.Value)).ToList();
    }
}
