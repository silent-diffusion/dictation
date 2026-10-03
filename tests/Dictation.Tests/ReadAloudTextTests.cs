using Dictation.Core.Reading;
using Xunit;

namespace Dictation.Tests;

public class ReadAloudTextTests
{
    static List<string> Pieces(string text) => ReadAloudText.Split(text).Select(s => text.Substring(s.Start, s.Length)).ToList();

    [Fact]
    public void Splits_into_sentences_with_their_punctuation()
    {
        Assert.Equal(new[] { "Hello there.", "How are you?", "Fine!" }, Pieces("Hello there. How are you? Fine!"));
    }

    [Fact]
    public void Line_breaks_split_lists_and_headings()
    {
        Assert.Equal(new[] { "Shopping list", "- milk", "- eggs" }, Pieces("Shopping list\n- milk\n\n- eggs\n"));
    }

    [Fact]
    public void Quotes_stay_with_their_sentence()
    {
        Assert.Equal(new[] { "She said \"stop.\"", "Then she left." }, Pieces("She said \"stop.\" Then she left."));
    }

    [Fact]
    public void Pieces_without_words_are_skipped()
    {
        Assert.Equal(new[] { "Real text." }, Pieces("--- \n\n Real text. \n * * *"));
    }

    [Fact]
    public void Long_sentences_break_at_commas_and_never_exceed_the_limit()
    {
        var clause = "this is one clause of a very long sentence that goes on";
        var text = string.Join(", ", Enumerable.Repeat(clause, 20)) + ".";
        var spans = ReadAloudText.Split(text);
        Assert.True(spans.Count > 3);
        Assert.All(spans, s => Assert.True(s.Length <= ReadAloudText.MaxPieceChars));
        Assert.All(spans.SkipLast(1), s => Assert.EndsWith(",", text.Substring(s.Start, s.Length)));
    }

    [Fact]
    public void Spans_point_into_the_original_text_in_order()
    {
        const string text = "  First line.\r\n\r\nSecond   line here.  ";
        var spans = ReadAloudText.Split(text);
        Assert.Equal(2, spans.Count);
        Assert.True(spans[0].End <= spans[1].Start);
        Assert.Equal("Second line here.", ReadAloudText.Speakable(text, spans[1]));
    }
}
