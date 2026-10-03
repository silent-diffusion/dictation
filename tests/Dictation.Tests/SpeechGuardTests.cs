using Dictation.Core.Speech;
using Xunit;

namespace Dictation.Tests;

public class SpeechGuardTests
{
    static readonly TimeSpan Short = TimeSpan.FromSeconds(0.6), Medium = TimeSpan.FromSeconds(1.5), Long = TimeSpan.FromSeconds(6);

    [Theory]
    [InlineData("Thank you.")]
    [InlineData("Thanks for watching!")]
    [InlineData("you")]
    public void Stock_phrases_from_short_recordings_are_dropped(string text) =>
        Assert.True(SpeechGuard.ShouldDiscard(text, Medium, peakLevel: 0.5f));

    [Fact]
    public void Stock_phrase_from_a_quiet_recording_is_dropped_even_when_long() =>
        Assert.True(SpeechGuard.ShouldDiscard("Thank you.", Long, peakLevel: 0.05f));

    [Fact]
    public void A_clearly_spoken_thank_you_is_kept() =>
        Assert.False(SpeechGuard.ShouldDiscard("Thank you.", Long, peakLevel: 0.6f));

    [Fact]
    public void A_short_quiet_recording_is_dropped() =>
        Assert.True(SpeechGuard.ShouldDiscard("Yes.", Short, peakLevel: 0.05f));

    [Fact]
    public void A_short_but_clearly_spoken_word_is_kept() =>
        Assert.False(SpeechGuard.ShouldDiscard("Yes.", Short, peakLevel: 0.5f));

    [Fact]
    public void Normal_dictation_is_kept() =>
        Assert.False(SpeechGuard.ShouldDiscard("Thank you for the update, I'll reply tomorrow.", Long, peakLevel: 0.4f));

    [Fact]
    public void Punctuation_only_is_dropped() =>
        Assert.True(SpeechGuard.ShouldDiscard("...", Long, peakLevel: 0.6f));
}
