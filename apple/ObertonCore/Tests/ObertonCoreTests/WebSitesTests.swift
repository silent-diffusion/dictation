import Foundation
import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/WebSitesTests.cs and AnalyticsTenTests.The_tally_counts_words_per_app_and_per_site:
// which site a browser tab is, counted by name only, in the usage counts and the word tally.

@Suite struct WebSitesTests {
    private func entry(_ app: String?, _ title: String?, _ text: String, date: Date = Date()) -> HistoryEntry {
        var e = HistoryEntry(transcription: text, aiEdit: nil, inserted: text, profileName: "Raw", model: nil, appName: app,
                             windowTitle: title, seconds: 2, turnaroundSeconds: 1, warning: nil)
        e.date = date
        return e
    }

    @Test(arguments: [
        ("chrome", "Inbox (3) - you@gmail.com - Gmail - Google Chrome", "Gmail"),
        ("chrome", "Lo-fi beats - YouTube - Google Chrome", "YouTube"),
        ("chrome", "(12) Lo-fi beats - YouTube - Google Chrome", "YouTube"),
        ("msedge", "Mail - Jane Doe - Outlook - Personal - Microsoft Edge", "Outlook"),
        ("msedge", "Mail - Jane Doe - Outlook and 2 more pages - Work - Microsoft Edge", "Outlook"),
        ("firefox", "Quarterly plan - Google Docs — Mozilla Firefox", "Google Docs"),
        ("chrome", "Chat | Microsoft Teams - Google Chrome", "Microsoft Teams"),
        ("chrome", "Feed | LinkedIn - Google Chrome", "LinkedIn"),
        ("chrome", "Home / X - Google Chrome", "X"),
        ("chrome", "Trip ideas - Claude - Google Chrome", "Claude"),
        ("chrome", "Claude - Google Chrome", "Claude"),
        ("brave", "Some page - Hacker News - Brave", "Hacker News"),
    ])
    func aBrowserTabGivesItsSite(_ app: String, _ title: String, _ site: String) {
        #expect(WebSites.site(app, title) == site)
    }

    @Test(arguments: [
        ("chrome", "My very private letter to the bank - Google Chrome"), // one part: no site name in it
        ("chrome", "Notes - this is a long private sentence about something - Google Chrome"), // too long to be a site
        ("chrome", "Google Chrome"),
        ("chrome", ""),
    ])
    func anythingElseIsOtherSites(_ app: String, _ title: String) {
        #expect(WebSites.site(app, title) == WebSites.other)
    }

    @Test func appsThatArentBrowsersHaveNoSite() {
        #expect(WebSites.site("notepad", "Untitled - Notepad") == nil)
        #expect(WebSites.site("TextEdit", "Untitled") == nil)
        #expect(WebSites.site(nil, "Inbox - Gmail") == nil)
    }

    // The Mac: the app is its name ("Google Chrome", "Safari"), and the window title is the tab's title, mostly without
    // the browser's name at the end; Windows' rules give the same site.
    @Test(arguments: [
        ("Google Chrome", "Inbox (3) - you@gmail.com - Gmail", "Gmail"),
        ("Safari", "Lo-fi beats - YouTube", "YouTube"),
        ("safari", "Claude", "Claude"),
        ("Microsoft Edge", "Mail - Jane Doe - Outlook - Personal - Microsoft\u{200B} Edge", "Outlook"),
        ("Firefox", "Quarterly plan - Google Docs — Private Browsing", "Google Docs"),
        ("Arc", "Some page - Hacker News", "Hacker News"),
        ("Brave Browser", "My very private letter to the bank", WebSites.other),
        ("Google Chrome Canary", "Feed | LinkedIn", "LinkedIn"),
    ])
    func macBrowsersByName(_ app: String, _ title: String, _ site: String) {
        #expect(WebSites.site(app, title) == site)
    }

    @Test func aTitleIsKeptToWindowsLength() {
        let long = String(repeating: "a", count: 300)
        #expect(HistoryEntry.keptTitle(long).utf16.count == 255)
        #expect(entry("Safari", long, "hi").windowTitle?.utf16.count == 255)
        // Never half a character at the cut.
        let emoji = String(repeating: "a", count: 254) + "😀" + "b"
        #expect(HistoryEntry.keptTitle(emoji) == String(repeating: "a", count: 254))
        #expect(HistoryEntry.keptTitle("Inbox - Gmail") == "Inbox - Gmail")
    }

    @Test func noTitleNoSite() {
        // The App Store build reads no titles: a browser dictation is counted under the browser only.
        #expect(entry("Safari", nil, "hi").site == nil)
        var log = UsageLog()
        log.record(entry("Safari", nil, "hi"))
        #expect(UsageLog.sitesOf(Array(log.days.values), "Safari").isEmpty)
        #expect(log.days.values.first?.apps["Safari"] == 1)
    }

    @Test func theWindowTitleIsKeptInHistory() throws {
        let e = entry("Google Chrome", "Inbox - Gmail - Google Chrome", "hi")
        let back = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(e))
        #expect(back.windowTitle == "Inbox - Gmail - Google Chrome")
        // Entries from before titles were kept.
        let old = #"{"id":"\#(UUID().uuidString)","date":0,"transcription":"hi","inserted":"hi","profileName":"Raw","seconds":1,"turnaroundSeconds":0}"#
        #expect(try JSONDecoder().decode(HistoryEntry.self, from: Data(old.utf8)).windowTitle == nil)
    }

    @Test func usageCountsSitesByNameOnly() throws {
        var u = UsageLog()
        u.record(entry("chrome", "Secret subject - you@x.com - Gmail - Google Chrome", "hi there"))
        u.record(entry("chrome", "Cats - YouTube - Google Chrome", "hello"))
        u.record(entry("chrome", "Other - Gmail - Google Chrome", "more"))
        let sites = UsageLog.sitesOf(Array(u.days.values), "chrome")
        #expect(sites[0] == ("Gmail", 2))
        #expect(sites[1] == ("YouTube", 1))
        let json = String(decoding: try JSONEncoder().encode(u), as: UTF8.self)
        #expect(!json.contains("Secret"))
        #expect(!json.contains("Cats"))
        #expect(!json.contains("x.com"))
    }

    @Test func olderCountsGetTheirSitesFromHistoryOnce() throws {
        let e = entry("chrome", "Inbox - Gmail - Google Chrome", "hi")
        // A file from before sites: the dictation counted, no sites.
        let file = #"{"days":{"\#(UsageLog.key(Date()))":{"dictations":1,"words":1,"apps":{"chrome":1}}},"samples":[]}"#
        var u = try JSONDecoder().decode(UsageLog.self, from: Data(file.utf8))
        #expect(u.version == 1)
        let filled = u.fillSites(from: [e])
        #expect(filled)
        #expect(UsageLog.sitesOf(Array(u.days.values), "chrome").map(\.site) == ["Gmail"])
        #expect(UsageLog.sitesOf(Array(u.days.values), "chrome").map(\.count) == [1])
        var again = try JSONDecoder().decode(UsageLog.self, from: JSONEncoder().encode(u)) // not counted twice
        let filledAgain = again.fillSites(from: [e])
        #expect(!filledAgain)
        #expect(UsageLog.sitesOf(Array(again.days.values), "chrome").map(\.count) == [1])
        // A new log never needs it.
        #expect(UsageLog().version == 2)
    }

    @Test func sitesAndBrowsersIgnoreCase() {
        var u = UsageLog()
        u.record(entry("Safari", "Inbox - Gmail", "hi"))
        u.record(entry("safari", "Inbox - gmail", "hi"))
        let sites = UsageLog.sitesOf(Array(u.days.values), "SAFARI")
        #expect(sites.count == 1)
        #expect(sites.first?.count == 2)
    }

    @Test func theTallyCountsWordsPerAppAndPerSite() {
        let tally = WordTally(seed: [
            entry("chrome", "Inbox - Gmail - Google Chrome", "quarterly invoices quarterly invoices"),
            entry("chrome", "Cats - YouTube - Google Chrome", "kittens"),
            entry("notepad", "Untitled - Notepad", "grocery list"),
        ])
        let days = tally.days
        #expect(WordTally.appKey("chrome", "Gmail") == "chrome › Gmail")
        #expect(WordTally.top(WordTally.forApp(days, "chrome › Gmail"), \.words, 5).first { $0.key == "invoices" }?.count == 2)
        #expect(!WordTally.top(WordTally.forApp(days, "chrome › Gmail"), \.words, 5).contains { $0.key == "kittens" })
        #expect(WordTally.top(WordTally.forApp(days, "chrome"), \.words, 5).contains { $0.key == "kittens" })
        #expect(WordTally.top(WordTally.forApp(days, "notepad"), \.words, 5).contains { $0.key == "grocery" })
        #expect(!WordTally.top(WordTally.forApp(days, "notepad"), \.words, 5).contains { $0.key == "invoices" })
        // Every app together is still the whole.
        #expect(WordTally.top(days, \.words, 10).contains { $0.key == "grocery" })
    }
}
