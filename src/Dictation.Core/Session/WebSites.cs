using System.Text.RegularExpressions;

namespace Dictation.Core.Session;

/// <summary>
/// Which website a dictation went into, when it went into a browser: worked out from the browser window's title, which
/// is the open tab's title and usually ends with the site's name ("Inbox (3) - you@gmail.com - Gmail - Google Chrome").
/// Only a short site name comes out, never the rest of the title (which may hold a subject or a document's name): a
/// known site by its usual name, or else the title's last part when it is short enough to be a site's name, or else
/// <see cref="Other"/>.
/// </summary>
public static class WebSites
{
    /// <summary>A browser tab whose site couldn't be told.</summary>
    public const string Other = "Other sites";

    static readonly HashSet<string> Browsers = new(StringComparer.OrdinalIgnoreCase)
    {
        "chrome", "msedge", "firefox", "brave", "opera", "opera_gx", "vivaldi", "arc", "chromium", "iexplore", "zen",
        "floorp", "librewolf", "waterfox", "thorium", "browser", "safari", "duckduckgo", "comet", "dia",
    };

    public static bool IsBrowser(string? process) => !string.IsNullOrEmpty(process) && Browsers.Contains(process);

    /// <summary>What browsers add at the end of a title: their own name, and Edge's profile.</summary>
    static readonly Regex BrowserPart = new(
        @"^(google chrome|chrome|chromium|microsoft edge|edge|mozilla firefox|firefox|firefox developer edition|firefox nightly|" +
        @"mozilla firefox private browsing|brave|opera|vivaldi|arc|zen browser|floorp|librewolf|waterfox|thorium|internet explorer|" +
        @"personal|work|profile \d+|inprivate|\[inprivate\]|private browsing|duckduckgo|comet|dia)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    static readonly Regex Separator = new(@"\s+[-–—|·/]\s+", RegexOptions.Compiled);
    static readonly Regex MorePages = new(@"\s+and \d+ more pages?$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex Counter = new(@"^\(\d+\+?\)\s*", RegexOptions.Compiled);

    /// <summary>Known sites: the name shown, and the names their tab titles end with.</summary>
    static readonly (string Name, string[] Titles)[] Known =
    {
        ("Gmail", new[] { "Gmail" }),
        ("Outlook", new[] { "Outlook", "Outlook.com", "Microsoft Outlook", "Outlook (PWA)" }),
        ("YouTube", new[] { "YouTube", "YouTube Studio", "YouTube Music" }),
        ("Google Docs", new[] { "Google Docs" }),
        ("Google Sheets", new[] { "Google Sheets" }),
        ("Google Slides", new[] { "Google Slides" }),
        ("Google Drive", new[] { "Google Drive" }),
        ("Google Calendar", new[] { "Google Calendar", "Calendar" }),
        ("Google Keep", new[] { "Google Keep" }),
        ("Google Search", new[] { "Google Search", "Google" }),
        ("Google Chat", new[] { "Google Chat", "Chat" }),
        ("Google Meet", new[] { "Google Meet", "Meet" }),
        ("ChatGPT", new[] { "ChatGPT" }),
        ("Claude", new[] { "Claude" }),
        ("Gemini", new[] { "Gemini", "Google Gemini" }),
        ("Copilot", new[] { "Copilot", "Microsoft Copilot", "Microsoft 365 Copilot" }),
        ("Perplexity", new[] { "Perplexity" }),
        ("Slack", new[] { "Slack" }),
        ("Microsoft Teams", new[] { "Microsoft Teams", "Teams" }),
        ("Discord", new[] { "Discord" }),
        ("WhatsApp", new[] { "WhatsApp" }),
        ("Messenger", new[] { "Messenger" }),
        ("Telegram", new[] { "Telegram", "Telegram Web" }),
        ("Notion", new[] { "Notion" }),
        ("Word", new[] { "Word", "Microsoft Word", "Microsoft Word Online" }),
        ("Excel", new[] { "Excel", "Microsoft Excel", "Microsoft Excel Online" }),
        ("PowerPoint", new[] { "PowerPoint", "Microsoft PowerPoint", "Microsoft PowerPoint Online" }),
        ("OneDrive", new[] { "OneDrive", "Microsoft OneDrive" }),
        ("SharePoint", new[] { "SharePoint" }),
        ("LinkedIn", new[] { "LinkedIn" }),
        ("Facebook", new[] { "Facebook" }),
        ("Instagram", new[] { "Instagram" }),
        ("Reddit", new[] { "Reddit" }),
        ("X", new[] { "X", "Twitter" }),
        ("GitHub", new[] { "GitHub" }),
        ("Jira", new[] { "Jira" }),
        ("Confluence", new[] { "Confluence" }),
        ("Trello", new[] { "Trello" }),
        ("Asana", new[] { "Asana" }),
        ("Figma", new[] { "Figma" }),
        ("Canva", new[] { "Canva" }),
        ("Wikipedia", new[] { "Wikipedia" }),
        ("Amazon", new[] { "Amazon.com", "Amazon" }),
        ("Zoom", new[] { "Zoom" }),
    };

    static readonly Dictionary<string, string> ByTitle = Known
        .SelectMany(k => k.Titles.Select(t => (t, k.Name)))
        .DistinctBy(x => x.t, StringComparer.OrdinalIgnoreCase).ToDictionary(x => x.t, x => x.Name, StringComparer.OrdinalIgnoreCase);

    /// <summary>The site a dictation into <paramref name="process"/> went to, from its window title; null when the
    /// app isn't a browser.</summary>
    public static string? Site(string? process, string? title)
    {
        if (!IsBrowser(process)) return null;
        var t = (title ?? "").Replace(((char)0x200B).ToString(), "").Trim(); // Edge writes "Microsoft​ Edge" with a zero-width space
        var parts = Separator.Split(t).Select(p => Counter.Replace(MorePages.Replace(p.Trim(), ""), "").Trim())
            .Where(p => p.Length > 0).ToList();
        while (parts.Count > 0 && BrowserPart.IsMatch(parts[^1])) parts.RemoveAt(parts.Count - 1);
        if (parts.Count == 0) return Other;
        // A known site's name, the last one first (the site comes after the page's own title).
        for (var i = parts.Count - 1; i >= 0; i--)
        {
            if (ByTitle.TryGetValue(parts[i], out var known) && (i > 0 || parts.Count == 1)) return known;
        }
        // Otherwise the last part, if the title has more than one and that part is short enough to be a site's name.
        var last = parts[^1];
        if (parts.Count >= 2 && last.Length <= 24 && last.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 3
            && last.Any(char.IsLetter) && !last.Contains('@'))
            return last;
        return Other;
    }
}
