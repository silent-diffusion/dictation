using Dictation.Core.Infrastructure;
using Dictation.Core.Notes;
using Xunit;

namespace Dictation.Tests;

public class NotesMarkersTests
{
    [Fact]
    public void A_marker_is_a_flagged_line_with_its_time_an_anchor_and_a_change()
    {
        var s = new NoteSession();
        var by = new object();
        var changed = new List<(NoteDoc Doc, object? Source)>();
        s.Changed += (doc, source) => changed.Add((doc, source));
        s.AddMarker(754, by);
        Assert.Equal("⚑ 12:34\n", s.Transcript);
        var anchor = Assert.Single(s.TranscriptAnchors);
        Assert.Equal((0, 754.0), (anchor.Offset, anchor.Seconds));
        var m = Assert.Single(s.Markers);
        Assert.Equal((754.0, "12:34"), (m.Seconds, m.Label));
        var change = Assert.Single(changed);
        Assert.Equal(NoteDoc.Transcript, change.Doc);
        Assert.Same(by, change.Source!);
        Assert.Equal("", s.Heard); // what was heard never changes
    }

    [Theory]
    [InlineData(5.0, "0:05")]
    [InlineData(754.0, "12:34")]
    [InlineData(3599.9, "59:59")]
    [InlineData(3600.0, "1:00:00")]
    [InlineData(3723.0, "1:02:03")]
    [InlineData(37230.0, "10:20:30")]
    public void The_hours_show_once_there_are_any(double seconds, string label) =>
        Assert.Equal(label, NoteSession.MarkerLabel(seconds));

    [Fact]
    public void An_hour_in_the_line_has_the_hours()
    {
        var s = new NoteSession();
        s.AddMarker(3723);
        Assert.Equal("⚑ 1:02:03\n", s.Transcript);
    }

    [Fact]
    public void A_marker_after_heard_text_starts_a_new_line_and_the_next_piece_follows_on_one()
    {
        var s = new NoteSession();
        s.AppendHeard("hello world", 1.0);
        s.AddMarker(12.5);
        s.AppendHeard("next piece", 15.0);
        Assert.Equal("hello world\n⚑ 0:12\nnext piece", s.Transcript);
        Assert.Equal(new[] { 0, 12, 19 }, s.TranscriptAnchors.Select(a => a.Offset));
        Assert.Equal(1.0, s.SecondsAt(NoteDoc.Transcript, 5));
        Assert.Equal(12.5, s.SecondsAt(NoteDoc.Transcript, 14)); // a right-click on the marker's line
        Assert.Equal(15.0, s.SecondsAt(NoteDoc.Transcript, 20));
        Assert.Equal("hello world next piece", s.Heard);
    }

    [Fact]
    public void A_marker_after_a_typed_line_doesnt_double_the_break()
    {
        var s = new NoteSession();
        s.Set(NoteDoc.Transcript, "Agenda: budget\n", null); // the dashboard draft, as a new session takes it
        s.AddMarker(3);
        Assert.Equal("Agenda: budget\n⚑ 0:03\n", s.Transcript);
        Assert.Equal(15, Assert.Single(s.TranscriptAnchors).Offset);
    }

    [Fact]
    public void A_marker_while_the_ai_works_is_formatted_next_time()
    {
        var s = new NoteSession();
        s.AppendHeard("first part", 0);
        var take = s.BeginFormat()!.Value;
        s.AddMarker(30);
        s.EndFormat(take.Heard, take.Sent, "First part.", take.Seconds, false);
        Assert.Equal("First part.", s.Formatted);
        Assert.Equal("first part".Length, s.FormattedThrough);
        Assert.Equal("⚑ 0:30", s.BeginFormat()!.Value.Sent); // the marker's line goes to the AI with the next piece
        Assert.Equal(30.0, s.BeginFormat()!.Value.Seconds);
    }

    [Fact]
    public void Markers_are_kept_in_the_session_file()
    {
        var s = new NoteSession();
        s.AddMarker(754);
        s.AddMarker(3723);
        var json = System.Text.Json.JsonSerializer.Serialize(s, JsonStore.Options);
        var back = System.Text.Json.JsonSerializer.Deserialize<NoteSession>(json, JsonStore.Options)!;
        Assert.Equal(new[] { (754.0, "12:34"), (3723.0, "1:02:03") }, back.Markers.Select(m => (m.Seconds, m.Label)));
        Assert.Equal(s.Transcript, back.Transcript);
    }

    [Fact]
    public void The_ai_is_told_to_keep_the_markers_lines_only_when_there_are_some()
    {
        var with = NotesFormat.Instructions("We start.\n⚑ 1:23\nWe go on.");
        Assert.Contains("⚑", with);
        Assert.Contains("own line", with);
        Assert.DoesNotContain("⚑", NotesFormat.Instructions("We start and we go on."));
    }

    static NoteSession Session() => new()
    {
        Title = "Product sync", Summary = "Ship Monday.", Formatted = "We ship on Monday.", Transcript = "we ship on monday", Seconds = 3725,
        Started = new DateTime(2026, 10, 17, 9, 0, 0), // fixed: the export's date line must never read a marker's time
    };

    [Fact]
    public void Everything_lists_the_markers_after_the_summary()
    {
        var s = Session();
        s.Markers.Add(new NoteMarker { Seconds = 754, Label = "12:34" });
        s.Markers.Add(new NoteMarker { Seconds = 3723, Label = "1:02:03" });

        var md = NotesExport.Build(s, NotesExport.Part.Everything, markdown: true).ReplaceLineEndings("\n");
        Assert.Contains("## Markers\n\n- 12:34\n- 1:02:03\n\n## Formatted", md);
        Assert.True(md.IndexOf("## Summary", StringComparison.Ordinal) < md.IndexOf("## Markers", StringComparison.Ordinal));

        var txt = NotesExport.Build(s, NotesExport.Part.Everything, markdown: false).ReplaceLineEndings("\n");
        Assert.Contains("MARKERS\n\n12:34\n1:02:03\n\nFORMATTED", txt);

        // One text alone has no markers section.
        Assert.DoesNotContain("12:34", NotesExport.Build(s, NotesExport.Part.Transcript, markdown: false));
        Assert.DoesNotContain("Markers", NotesExport.Build(s, NotesExport.Part.Summary, markdown: true));
    }

    [Fact]
    public void Everything_is_unchanged_without_markers()
    {
        var md = NotesExport.Build(Session(), NotesExport.Part.Everything, markdown: true).ReplaceLineEndings("\n");
        Assert.DoesNotContain("Markers", md);
        Assert.Contains("## Summary\n\nShip Monday.\n\n## Formatted\n\nWe ship on Monday.\n\n## Transcript\n\nwe ship on monday", md);
        var txt = NotesExport.Build(Session(), NotesExport.Part.Everything, markdown: false).ReplaceLineEndings("\n");
        Assert.Contains("SUMMARY\n\nShip Monday.\n\nFORMATTED\n\n", txt);
    }
}
