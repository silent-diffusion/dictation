using Dictation.Core.Notes;
using Xunit;

namespace Dictation.Tests;

public class NotesRedoTests
{
    [Fact]
    public void The_recording_is_cut_in_the_pauses_near_every_fifteen_seconds()
    {
        var pauses = new List<AudioPause> { new() { Start = 13, End = 14 }, new() { Start = 40, End = 41 } };
        var parts = NotesRedo.PlanParts(60, pauses);
        Assert.Equal((0.0, 13.5), parts[0]);          // the pause near 15 s
        Assert.Equal((13.5, 28.5), parts[1]);         // no pause near 28.5 s: cut there
        Assert.Equal((28.5, 40.5), parts[2]);         // the pause near 43.5 s
        Assert.Equal((40.5, 60.0), parts[^1]);        // the rest, under 23 s, in one
        Assert.Single(NotesRedo.PlanParts(10, pauses));
    }

    [Fact]
    public void A_new_transcript_keeps_the_markers_in_place_and_drops_the_old_steps()
    {
        var s = new NoteSession();
        s.AppendHeard("old words", 0);
        s.AddMarker(20);
        var t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, "Old words.", t.Seconds, false);
        s.Summary = "Old summary.";

        s.ReplaceTranscript(new[] { (0.0, "First part."), (15.0, "Second part."), (30.0, "Third part.") });
        Assert.Equal("First part. Second part.\n⚑ 0:20\nThird part.", s.Transcript);
        Assert.Equal("First part. Second part. Third part.", s.Heard);
        Assert.Equal("", s.Formatted);
        Assert.Empty(s.Chunks);
        Assert.Equal("", s.Summary);
        Assert.Single(s.Markers);
        Assert.Equal(20, s.SecondsAt(NoteDoc.Transcript, s.Transcript.IndexOf('⚑')));
    }

    [Fact]
    public void Formatting_again_goes_part_by_part_at_piece_ends()
    {
        var s = new NoteSession();
        for (var i = 0; i < 6; i++) s.AppendHeard($"Sentence number {i} has five words.", i * 10);
        var t = s.BeginFormatPart(14)!.Value;           // two pieces of 6 words fit, a third doesn't
        Assert.Equal("Sentence number 0 has five words. Sentence number 1 has five words.", t.Sent);
        Assert.Equal(t.Sent, t.Heard);
        s.EndFormat(t.Heard, t.Sent, t.Sent, t.Seconds, false);
        var u = s.BeginFormatPart(14)!.Value;
        Assert.StartsWith("Sentence number 2", u.Sent);
        Assert.Equal(20, u.Seconds);
        s.EndFormat(u.Heard, u.Sent, u.Sent, u.Seconds, false);
        var v = s.BeginFormatPart(100)!.Value;
        s.EndFormat(v.Heard, v.Sent, v.Sent, v.Seconds, false);
        Assert.Null(s.BeginFormatPart(14));
        Assert.Equal(s.Heard.Length, s.HeardFormattedThrough);
        Assert.Equal(s.Transcript.Length, s.FormattedThrough);
    }
}
