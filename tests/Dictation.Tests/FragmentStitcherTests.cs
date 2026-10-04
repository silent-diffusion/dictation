using Dictation.Core.Settings;
using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

/// <summary>Joining live pieces without the AI (the Raw profile, and the raw transcript of every dictation).</summary>
public class FragmentStitcherTests
{
    static string Join(params string[] pieces) => FragmentStitcher.Join(pieces);

    [Fact]
    public void Whole_sentences_are_joined_with_a_space() =>
        Assert.Equal("I went to the store. Then I went home.", Join("I went to the store.", "Then I went home."));

    [Fact]
    public void A_piece_cut_mid_sentence_continues_in_lowercase() =>
        Assert.Equal("I went to the store and then bought milk.", Join("I went to the store", "And then bought milk."));

    [Fact]
    public void Names_at_a_cut_keep_their_capital() =>
        Assert.Equal("Yesterday we talked to Sarah about it.", Join("Yesterday we talked to", "Sarah about it."));

    [Fact]
    public void A_word_lowercase_elsewhere_is_lowercased_at_a_cut() =>
        Assert.Equal("The budget for the project is fine, and the project starts soon.",
            Join("The budget for the", "Project is fine, and the project starts soon."));

    [Fact]
    public void A_full_stop_before_a_lowercase_continuation_goes() =>
        Assert.Equal("I went to the store and bought milk.", Join("I went to the store.", "and bought milk."));

    [Fact]
    public void Abbreviations_keep_their_dot() =>
        Assert.Equal("Bring fruit, e.g. apples and pears.", Join("Bring fruit, e.g.", "apples and pears."));

    [Fact]
    public void A_word_said_across_the_cut_appears_once() =>
        Assert.Equal("Put it on the table please.", Join("Put it on the", "the table please."));

    [Fact]
    public void I_keeps_its_capital() =>
        Assert.Equal("Tomorrow I think I will go.", Join("Tomorrow", "I think I will go."));

    [Fact]
    public void Empty_pieces_and_extra_spaces_are_ignored() =>
        Assert.Equal("Hello there.", Join("  hello  ", "", " there ."));

    [Fact]
    public void Raw_profile_skips_the_ai_and_is_built_in()
    {
        var raw = BuiltInProfiles.Create().Single(p => p.Id == BuiltInProfiles.RawId);
        Assert.False(raw.AutoProcess);
        Assert.Contains(BuiltInProfiles.RawId, BuiltInProfiles.FixedIds);
    }
}
