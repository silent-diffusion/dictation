using Dictation.Core.Session;
using Xunit;

namespace Dictation.Tests;

public class WebSitesTests
{
    [Theory]
    [InlineData("chrome", "Inbox (3) - you@gmail.com - Gmail - Google Chrome", "Gmail")]
    [InlineData("chrome", "Lo-fi beats - YouTube - Google Chrome", "YouTube")]
    [InlineData("chrome", "(12) Lo-fi beats - YouTube - Google Chrome", "YouTube")]
    [InlineData("msedge", "Mail - Jane Doe - Outlook - Personal - Microsoft Edge", "Outlook")]
    [InlineData("msedge", "Mail - Jane Doe - Outlook and 2 more pages - Work - Microsoft Edge", "Outlook")]
    [InlineData("firefox", "Quarterly plan - Google Docs — Mozilla Firefox", "Google Docs")]
    [InlineData("chrome", "Chat | Microsoft Teams - Google Chrome", "Microsoft Teams")]
    [InlineData("chrome", "Feed | LinkedIn - Google Chrome", "LinkedIn")]
    [InlineData("chrome", "Home / X - Google Chrome", "X")]
    [InlineData("chrome", "Trip ideas - Claude - Google Chrome", "Claude")]
    [InlineData("chrome", "Claude - Google Chrome", "Claude")]
    [InlineData("brave", "Some page - Hacker News - Brave", "Hacker News")]
    public void A_browser_tab_gives_its_site(string process, string title, string site) =>
        Assert.Equal(site, WebSites.Site(process, title));

    [Theory]
    [InlineData("chrome", "My very private letter to the bank - Google Chrome")] // one part: no site name in it
    [InlineData("chrome", "Notes - this is a long private sentence about something - Google Chrome")] // too long to be a site
    [InlineData("chrome", "Google Chrome")]
    [InlineData("chrome", "")]
    public void Anything_else_is_other_sites(string process, string title) =>
        Assert.Equal(WebSites.Other, WebSites.Site(process, title));

    [Fact]
    public void Apps_that_arent_browsers_have_no_site() =>
        Assert.Null(WebSites.Site("notepad", "Untitled - Notepad"));

    [Fact]
    public void Usage_counts_sites_by_name_only()
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-usage-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var u = new UsageStore(path);
            u.Record(new HistoryEntry { Time = DateTime.Now, Final = "hi there", App = "chrome", WindowTitle = "Secret subject - you@x.com - Gmail - Google Chrome" });
            u.Record(new HistoryEntry { Time = DateTime.Now, Final = "hello", App = "chrome", WindowTitle = "Cats - YouTube - Google Chrome" });
            u.Record(new HistoryEntry { Time = DateTime.Now, Final = "more", App = "chrome", WindowTitle = "Other - Gmail - Google Chrome" });
            var sites = UsageStore.SitesOf(u.Days, "chrome");
            Assert.Equal(("Gmail", 2), sites[0]);
            Assert.Equal(("YouTube", 1), sites[1]);
            var json = File.ReadAllText(path);
            Assert.DoesNotContain("Secret", json);
            Assert.DoesNotContain("Cats", json);
            Assert.DoesNotContain("x.com", json);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Older_counts_get_their_sites_from_history_once()
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-usage-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var e = new HistoryEntry { Time = DateTime.Now, Final = "hi", App = "chrome", WindowTitle = "Inbox - Gmail - Google Chrome" };
            // A file from before sites: the dictation counted, no sites.
            File.WriteAllText(path, $$$"""{"Version":1,"Days":[{"Day":"{{{DateTime.Today:yyyy-MM-dd}}}T00:00:00","Dictations":1,"Words":1,"Apps":{"chrome":1}}]}""");
            var u = new UsageStore(path, new[] { e });
            Assert.Equal(("Gmail", 1), UsageStore.SitesOf(u.Days, "chrome").Single());
            var again = new UsageStore(path, new[] { e }); // not counted twice
            Assert.Equal(("Gmail", 1), UsageStore.SitesOf(again.Days, "chrome").Single());
        }
        finally { File.Delete(path); }
    }
}
