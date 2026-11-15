import Foundation

/// Which website a dictation went into, when it went into a browser: worked out from the browser window's title, which
/// is the open tab's title and usually ends with the site's name ("Inbox (3) - you@gmail.com - Gmail - Google Chrome")
/// (Dictation.Core/Session/WebSites.cs). Only a short site name comes out, never the rest of the title (which may hold a
/// subject or a document's name): a known site by its usual name, or else the title's last part when it is short enough
/// to be a site's name, or else `other`.
///
/// Only the title, as on Windows: a browser's address (Accessibility's AXURL/AXDocument) would name the same tab as
/// "github.com" where Windows says "GitHub", so it isn't read.
public enum WebSites {
    /// A browser tab whose site couldn't be told.
    public static let other = "Other sites"

    /// Windows' process names, and the same browsers by their Mac app names (`HistoryEntry.appName`, the app's
    /// localized name), with their beta and nightly builds (one process name on Windows). Told apart ignoring case.
    static let browsers: Set<String> = Set([
        "chrome", "msedge", "firefox", "brave", "opera", "opera_gx", "vivaldi", "arc", "chromium", "iexplore", "zen",
        "floorp", "librewolf", "waterfox", "thorium", "browser", "safari", "duckduckgo", "comet", "dia",
        "Google Chrome", "Google Chrome Beta", "Google Chrome Dev", "Google Chrome Canary", "Microsoft Edge",
        "Microsoft Edge Beta", "Microsoft Edge Dev", "Microsoft Edge Canary", "Firefox Developer Edition", "Firefox Nightly",
        "Brave Browser", "Brave Browser Beta", "Brave Browser Nightly", "Opera GX", "Zen Browser", "LibreWolf", "Yandex",
        "Safari Technology Preview", "DuckDuckGo",
    ].map { $0.lowercased() })

    public static func isBrowser(_ app: String?) -> Bool {
        guard let app, !app.isEmpty else { return false }
        return browsers.contains(app.lowercased())
    }

    /// What browsers add at the end of a title: their own name, and Edge's profile.
    private static let browserPart = try! NSRegularExpression(pattern:
        "^(google chrome|chrome|chromium|microsoft edge|edge|mozilla firefox|firefox|firefox developer edition|firefox nightly|"
            + "mozilla firefox private browsing|brave|opera|vivaldi|arc|zen browser|floorp|librewolf|waterfox|thorium|internet explorer|"
            + "personal|work|profile \\d+|inprivate|\\[inprivate\\]|private browsing|duckduckgo|comet|dia)$",
        options: .caseInsensitive)
    private static let separator = try! NSRegularExpression(pattern: "\\s+[-–—|·/]\\s+")
    private static let morePages = try! NSRegularExpression(pattern: "\\s+and \\d+ more pages?$", options: .caseInsensitive)
    private static let counter = try! NSRegularExpression(pattern: "^\\(\\d+\\+?\\)\\s*")

    /// Known sites: the name shown, and the names their tab titles end with.
    static let known: [(name: String, titles: [String])] = [
        ("Gmail", ["Gmail"]),
        ("Outlook", ["Outlook", "Outlook.com", "Microsoft Outlook", "Outlook (PWA)"]),
        ("YouTube", ["YouTube", "YouTube Studio", "YouTube Music"]),
        ("Google Docs", ["Google Docs"]),
        ("Google Sheets", ["Google Sheets"]),
        ("Google Slides", ["Google Slides"]),
        ("Google Drive", ["Google Drive"]),
        ("Google Calendar", ["Google Calendar", "Calendar"]),
        ("Google Keep", ["Google Keep"]),
        ("Google Search", ["Google Search", "Google"]),
        ("Google Chat", ["Google Chat", "Chat"]),
        ("Google Meet", ["Google Meet", "Meet"]),
        ("ChatGPT", ["ChatGPT"]),
        ("Claude", ["Claude"]),
        ("Gemini", ["Gemini", "Google Gemini"]),
        ("Copilot", ["Copilot", "Microsoft Copilot", "Microsoft 365 Copilot"]),
        ("Perplexity", ["Perplexity"]),
        ("Slack", ["Slack"]),
        ("Microsoft Teams", ["Microsoft Teams", "Teams"]),
        ("Discord", ["Discord"]),
        ("WhatsApp", ["WhatsApp"]),
        ("Messenger", ["Messenger"]),
        ("Telegram", ["Telegram", "Telegram Web"]),
        ("Notion", ["Notion"]),
        ("Word", ["Word", "Microsoft Word", "Microsoft Word Online"]),
        ("Excel", ["Excel", "Microsoft Excel", "Microsoft Excel Online"]),
        ("PowerPoint", ["PowerPoint", "Microsoft PowerPoint", "Microsoft PowerPoint Online"]),
        ("OneDrive", ["OneDrive", "Microsoft OneDrive"]),
        ("SharePoint", ["SharePoint"]),
        ("LinkedIn", ["LinkedIn"]),
        ("Facebook", ["Facebook"]),
        ("Instagram", ["Instagram"]),
        ("Reddit", ["Reddit"]),
        ("X", ["X", "Twitter"]),
        ("GitHub", ["GitHub"]),
        ("Jira", ["Jira"]),
        ("Confluence", ["Confluence"]),
        ("Trello", ["Trello"]),
        ("Asana", ["Asana"]),
        ("Figma", ["Figma"]),
        ("Canva", ["Canva"]),
        ("Wikipedia", ["Wikipedia"]),
        ("Amazon", ["Amazon.com", "Amazon"]),
        ("Zoom", ["Zoom"]),
    ]

    /// A tab title's last part → the known site's name, ignoring case (the first site to claim a title keeps it).
    private static let byTitle: [String: String] = {
        var d: [String: String] = [:]
        for k in known { for t in k.titles where d[t.lowercased()] == nil { d[t.lowercased()] = k.name } }
        return d
    }()

    /// The site a dictation into `app` went to, from its window title; nil when the app isn't a browser.
    public static func site(_ app: String?, _ title: String?) -> String? {
        guard isBrowser(app) else { return nil }
        // Edge writes "Microsoft​ Edge" with a zero-width space.
        let t = (title ?? "").replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = split(t).map { p in
            replace(counter, in: replace(morePages, in: p.trimmingCharacters(in: .whitespacesAndNewlines)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        while let last = parts.last, matches(browserPart, last) { parts.removeLast() }
        guard !parts.isEmpty else { return other }
        // A known site's name, the last one first (the site comes after the page's own title).
        for i in parts.indices.reversed() {
            if let name = byTitle[parts[i].lowercased()], i > 0 || parts.count == 1 { return name }
        }
        // Otherwise the last part, if the title has more than one and that part is short enough to be a site's name.
        let last = parts[parts.count - 1]
        if parts.count >= 2, last.utf16.count <= 24, last.split(separator: " ").count <= 3, last.contains(where: \.isLetter),
           !last.contains("@") {
            return last
        }
        return other
    }

    private static func split(_ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = [], start = 0
        for m in separator.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out
    }

    private static func replace(_ rx: NSRegularExpression, in s: String) -> String {
        rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    private static func matches(_ rx: NSRegularExpression, _ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}
