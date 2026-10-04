using Dictation.Core.Insertion;
using Dictation.Core.Session;
using Dictation.Core.Settings;
using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

/// <summary>Profiles that rewrite the whole dictation at the end (e.g. "turn my thoughts into an email").</summary>
public class RewriteWholeTests
{
    const string Rambling =
        "okay so I need to tell Mark that the report is going to be late because the numbers from finance " +
        "came in on Thursday instead of Monday and um I think we can have it to him by next Wednesday " +
        "and also ask if he wants the summary slides too or just the spreadsheet";

    const string Email =
        "Hi Mark,\n\nThe report will be a few days late: finance sent the numbers on Thursday instead of Monday. " +
        "I expect to have it to you by next Wednesday.\n\nWould you like summary slides as well, or just the spreadsheet?\n\nThanks";

    [Fact]
    public void A_reshaped_email_passes_the_rewrite_safety_net() =>
        Assert.True(OutputSanitizer.IsPlausibleRewrite(Rambling, Email, out _));

    [Fact]
    public void A_short_note_may_grow_into_a_full_email() =>
        Assert.True(OutputSanitizer.IsPlausibleRewrite("tell mark the report is late",
            "Hi Mark,\n\nI wanted to let you know that the report will be a little late. I'll send it as soon as it's ready.\n\nBest regards", out _));

    [Theory]
    [InlineData("")]
    [InlineData("Late.")]
    public void Empty_or_nearly_nothing_is_rejected(string output) =>
        Assert.False(OutputSanitizer.IsPlausibleRewrite(Rambling, output, out _));

    [Fact]
    public void Runaway_output_is_rejected() =>
        Assert.False(OutputSanitizer.IsPlausibleRewrite("tell mark the report is late",
            string.Join(" ", Enumerable.Repeat("word", 80)), out _));

    [Fact]
    public void Live_text_may_be_replaced_by_a_much_shorter_rewrite()
    {
        Assert.False(LiveInsertion.IsPlausibleReplacement(Email, Rambling + " " + Rambling));
        Assert.True(LiveInsertion.IsPlausibleReplacement(Email, Rambling + " " + Rambling, rewrite: true));
        Assert.False(LiveInsertion.IsPlausibleReplacement("", Rambling, rewrite: true));
    }

    [Fact]
    public void A_rewrite_keeps_its_own_capitals_and_punctuation_mid_sentence()
    {
        var context = new InsertionContext("Draft: see below and", "");
        Assert.Equal(" Hi Mark,\n\nThanks.", ContextFit.Fit("Hi Mark,\n\nThanks.", context, spacingOnly: true));
        Assert.StartsWith(" hi", ContextFit.Fit("Hi Mark.", context, spacingOnly: false));
    }

    [Fact]
    public void Rewriting_profiles_are_told_to_lay_the_text_out()
    {
        var p = new Profile { Prompt = "Turn this into an email.", RewriteWhole = true };
        Assert.Contains("Lay the text out", OllamaTextProcessor.BuildSystemPrompt(p));
        p.RewriteWhole = false;
        Assert.Contains("Preserve any paragraph breaks", OllamaTextProcessor.BuildSystemPrompt(p));
    }
}
