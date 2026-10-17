using Dictation.Core.Audio;
using Dictation.Core.Notes;
using Dictation.Core.Text;
using NAudio.Wave;
using Xunit;

namespace Dictation.Tests;

public class NotesAudioTests
{
    [Fact]
    public void Resampling_48k_to_16k_keeps_the_pitch_and_a_third_of_the_samples()
    {
        var input = Enumerable.Range(0, 48000).Select(i => (float)Math.Sin(2 * Math.PI * 440 * i / 48000)).ToArray();
        var r = new Resampler(48000, 16000);
        var output = r.Process(input.AsSpan(0, 24000)).Concat(r.Process(input.AsSpan(24000))).ToArray();
        Assert.InRange(output.Length, 15990, 16000);
        var crossings = 0;
        for (var i = 1; i < output.Length; i++) if (output[i - 1] < 0 && output[i] >= 0) crossings++;
        Assert.InRange(crossings, 437, 442); // still 440 Hz over one second
        Assert.InRange(output.Max(), 0.9f, 1.01f);
    }

    [Fact]
    public void Stereo_float_is_averaged_to_mono()
    {
        var f = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
        var bytes = new byte[16];
        BitConverter.GetBytes(0.5f).CopyTo(bytes, 0);
        BitConverter.GetBytes(-0.1f).CopyTo(bytes, 4);
        BitConverter.GetBytes(1f).CopyTo(bytes, 8);
        BitConverter.GetBytes(1f).CopyTo(bytes, 12);
        var mono = LoopbackCapture.Downmix(bytes, 16, f);
        Assert.Equal(2, mono.Length);
        Assert.Equal(0.2f, mono[0], 3);
        Assert.Equal(1f, mono[1], 3);
    }

    static byte[] Pcm(params short[] s) => s.SelectMany(BitConverter.GetBytes).ToArray();
    static short[] Shorts(byte[] b) => Enumerable.Range(0, b.Length / 2).Select(i => BitConverter.ToInt16(b, 2 * i)).ToArray();

    [Fact]
    public void Mic_alone_passes_through_and_computer_audio_is_added_to_it()
    {
        var m = new NotesMixer();
        Assert.Equal(new short[] { 1000, -2000, 0 }, Shorts(m.MixWithMic(Pcm(1000, -2000, 0))));
        m.AddComputer(new[] { 0.5f, 0.5f });
        var mixed = Shorts(m.MixWithMic(Pcm(1000, 1000, 1000)));
        Assert.InRange(mixed[0], 17380, 17388); // 1000 + half scale
        Assert.InRange(mixed[1], 17380, 17388);
        Assert.Equal(1000, mixed[2]); // no computer audio left: the mic alone
    }

    [Fact]
    public void Computer_audio_alone_is_padded_with_silence_and_never_clips()
    {
        var m = new NotesMixer();
        m.AddComputer(new[] { 2f });
        Assert.Equal(new short[] { 32767, 0, 0 }, Shorts(m.TakeComputer(3)));
    }

    [Fact]
    public void A_runaway_computer_backlog_is_trimmed_to_a_second()
    {
        var m = new NotesMixer();
        m.AddComputer(Enumerable.Repeat(0.25f, NotesMixer.MaxBacklog * 3).ToArray());
        m.MixWithMic(new byte[200]);
        // After the trim, about a second (plus the chunk) waits: the next second is still computer audio, then silence.
        Assert.Contains((short)0, Shorts(m.TakeComputer(NotesMixer.MaxBacklog + 500)));
    }
}

public class NoteSessionTests
{
    [Fact]
    public void Pieces_are_appended_with_their_time_and_anchors_follow_edits()
    {
        var s = new NoteSession();
        s.AppendHeard("hello world", 1.0);
        s.AppendHeard("second piece", 5.0);
        Assert.Equal("hello world second piece", s.Transcript);
        Assert.Equal(new[] { 0, 12 }, s.TranscriptAnchors.Select(a => a.Offset));

        s.Set(NoteDoc.Transcript, "NOTE " + s.Transcript, null); // the user types at the start
        Assert.Equal(new[] { 5, 17 }, s.TranscriptAnchors.Select(a => a.Offset));
        Assert.Equal(5.0, s.SecondsAt(NoteDoc.Transcript, 18));
        Assert.Equal(1.0, s.SecondsAt(NoteDoc.Transcript, 7));
        Assert.Equal("hello world second piece", s.Heard); // what was heard never changes
    }

    [Theory]
    [InlineData("abcdef", "abXYef", 2, 2, 2)]
    [InlineData("abc", "abc!", 3, 0, 1)]
    [InlineData("hello", "", 0, 5, 0)]
    public void An_edit_is_found_as_one_change(string old, string now, int offset, int removed, int added) =>
        Assert.Equal((offset, removed, added), NoteSession.Change(old, now));

    [Fact]
    public void Positions_move_with_an_edit()
    {
        Assert.Equal(3, NoteSession.Move(3, 5, 2, 4));  // before: stays
        Assert.Equal(12, NoteSession.Move(10, 5, 2, 4)); // after: shifts by +2
        Assert.Equal(9, NoteSession.Move(6, 5, 2, 4));   // inside the removed part: lands after the new text
        Assert.Equal(5, NoteSession.Move(5, 5, 0, 3));   // a boundary: typing right at it stays after it
        Assert.Equal(8, NoteSession.MoveAnchor(5, 5, 0, 3)); // an anchor: typing right at it goes before it
    }

    [Fact]
    public void Formatting_takes_what_is_new_and_appends_the_ai_output()
    {
        var s = new NoteSession();
        s.AppendHeard("so the plan is simple", 0);
        var take = s.BeginFormat()!.Value;
        Assert.Equal("so the plan is simple", take.Sent);
        s.AppendHeard("and then more", 30); // arrives while the AI works
        s.EndFormat(take.Heard, take.Sent, "The plan is simple.", take.Seconds, false);
        Assert.Equal("The plan is simple.", s.Formatted);
        Assert.Equal(1, s.UnformattedWords() > 0 ? 1 : 0);
        Assert.Equal("and then more", s.BeginFormat()!.Value.Sent); // only the new part next time
    }

    [Fact]
    public void An_edit_while_the_ai_works_doesnt_lose_the_boundary()
    {
        var s = new NoteSession();
        s.AppendHeard("first part", 0);
        var take = s.BeginFormat()!.Value;
        s.Set(NoteDoc.Transcript, "My note. " + s.Transcript, null);
        s.EndFormat(take.Heard, take.Sent, "First part.", take.Seconds, false);
        Assert.Equal(s.Transcript.Length, s.FormattedThrough);
        Assert.Equal(0, s.UnformattedWords());
    }

    [Fact]
    public void The_summary_is_not_overwritten_if_the_user_edited_it_meanwhile()
    {
        var s = new NoteSession();
        s.AppendHeard("words", 0);
        var take = s.BeginFormat()!.Value;
        s.EndFormat(take.Heard, take.Sent, "Words.", 0, false);
        Assert.Equal("Words.", s.BeginSummary());
        s.Set(NoteDoc.Summary, "Mine", null);
        Assert.False(s.EndSummary("AI summary", basedOn: ""));
        Assert.Equal("Mine", s.Summary);
        Assert.Equal("Words.", s.BeginSummary()); // still to do
        Assert.True(s.EndSummary("AI summary", basedOn: "Mine"));
        Assert.Equal("AI summary", s.Summary);
        Assert.Null(s.BeginSummary());
    }
}

public class LongDiffTests
{
    static int Edits(IReadOnlyList<DiffToken> d) => d.Count(t => t.Kind != DiffKind.Same);

    static void AssertReproduces(string a, string b, IReadOnlyList<DiffToken> d)
    {
        static string N(string w) => w.Trim('.', ',', '!', '?').ToLowerInvariant();
        Assert.Equal(LongDiff.Split(a).Select(N), d.Where(t => t.Kind != DiffKind.Added).Select(t => N(t.Word)));
        Assert.Equal(LongDiff.Split(b), d.Where(t => t.Kind != DiffKind.Removed).Select(t => t.Word));
    }

    [Theory]
    [InlineData("the cat sat on the mat", "the cat sat on a mat")]
    [InlineData("um so we ship it on Monday", "We ship it on Tuesday.")]
    [InlineData("a b c d e f", "x a c d y f z")]
    [InlineData("", "new words here")]
    [InlineData("old words gone", "")]
    public void Matches_the_short_diff(string a, string b)
    {
        var d = LongDiff.Compute(a, b);
        AssertReproduces(a, b, d);
        Assert.Equal(Edits(WordDiff.Compute(a, b)), Edits(d)); // just as few changes
    }

    [Fact]
    public void Copes_with_ten_thousand_words_and_few_edits()
    {
        var rng = new Random(7);
        var words = Enumerable.Range(0, 10000).Select(_ => "w" + rng.Next(500)).ToList();
        var edited = new List<string>(words);
        for (var k = 0; k < 40; k++) edited[rng.Next(edited.Count)] = "CHANGED" + k;
        edited.Insert(5000, "inserted");
        edited.RemoveAt(100);
        var a = string.Join(" ", words);
        var b = string.Join(" ", edited);
        var d = LongDiff.Compute(a, b);
        AssertReproduces(a, b, d);
        Assert.InRange(Edits(d), 2, 90);
    }
}

public class NotesEditsTests
{
    static NoteSession Formatted(string heard, string userTranscript, string ai)
    {
        var s = new NoteSession();
        s.AppendHeard(heard, 0);
        if (userTranscript != heard) s.Set(NoteDoc.Transcript, userTranscript, null);
        var t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, ai, t.Seconds, false);
        return s;
    }

    static string Show(IReadOnlyList<EditPiece> pieces) => string.Join(" ", pieces.Select(p => p.Mark switch
    {
        EditMark.Plain => p.Text,
        EditMark.Paragraph => "|",
        EditMark.AiRemoved => "-" + p.Text,
        EditMark.AiAdded => "+" + p.Text,
        EditMark.AiParagraph => "¶",
        EditMark.UserRemoved => "u-" + p.Text,
        EditMark.UserChanged => "u~" + p.Text,
        _ => "u+" + p.Text,
    }));

    [Fact]
    public void The_ai_and_the_user_are_marked_apart()
    {
        var s = Formatted("um the overton release is ready", "um the Oberton release is ready", "The Oberton release is ready.");
        s.Set(NoteDoc.Formatted, s.Formatted + "\n\nCheck the date", null);
        Assert.Equal("-um The u-overton u~Oberton release is ready. | u+Check u+the u+date", Show(NotesEdits.Build(s)));
    }

    [Fact]
    public void A_paragraph_the_ai_made_is_marked()
    {
        var s = Formatted("first point second point", "first point second point", "First point.\n\nSecond point.");
        Assert.Equal("First point. ¶ Second point.", Show(NotesEdits.Build(s)));
    }

    [Fact]
    public void A_note_typed_into_the_transcript_is_a_note_and_the_tail_is_shown_too()
    {
        var s = Formatted("hello there", "hello there", "Hello there.");
        s.AppendHeard("next part here", 10);
        s.Set(NoteDoc.Transcript, s.Transcript + "\nmy note", null);
        Assert.Equal("Hello there. | next part here | u+my u+note", Show(NotesEdits.Build(s)));
    }

    [Fact]
    public void Words_the_user_removed_from_the_formatted_text()
    {
        var s = Formatted("we said this and that", "we said this and that", "We said this and that.");
        s.Set(NoteDoc.Formatted, "We said this.", null);
        Assert.Equal("We said this u-and u-that.", Show(NotesEdits.Build(s)));
    }

    [Fact]
    public void Notes_typed_before_the_session_are_the_users_own()
    {
        var s = new NoteSession();
        s.Set(NoteDoc.Transcript, "Agenda: budget\n", null); // the dashboard draft, as a new session takes it
        s.AppendHeard("so the budget is final", 2.0);
        Assert.Equal("Agenda: budget\nso the budget is final", s.Transcript);
        Assert.Equal(0.0, s.SecondsAt(NoteDoc.Transcript, 3));
        Assert.Equal(2.0, s.SecondsAt(NoteDoc.Transcript, s.Transcript.Length - 1));
        Assert.Equal("u+Agenda: u+budget | so the budget is final", Show(NotesEdits.Build(s)));

        var t = s.BeginFormat()!.Value;
        Assert.Equal("so the budget is final", t.Heard);
        s.EndFormat(t.Heard, t.Sent, t.Sent, t.Seconds, false);
        Assert.Equal("u+Agenda: u+budget | so the budget is final", Show(NotesEdits.Build(s)));
    }
}

public class NotesDraftTests
{
    [Fact]
    public void The_draft_goes_to_the_next_session_once()
    {
        var store = new NotesStore(load: false);
        store.SetDraft("Agenda: budget");
        Assert.Equal("Agenda: budget", store.Draft);
        Assert.Equal("Agenda: budget", store.TakeDraft());
        Assert.Equal("", store.Draft);
        Assert.Equal("", store.TakeDraft());
    }
}

public class NotesExportTests
{
    [Fact]
    public void Everything_as_markdown_has_the_title_and_each_part()
    {
        var s = new NoteSession { Title = "Product sync", Summary = "Ship Monday.", Formatted = "We ship on Monday.", Transcript = "we ship on monday", Seconds = 3725 };
        var md = NotesExport.Build(s, NotesExport.Part.Everything, markdown: true);
        Assert.StartsWith("# Product sync", md);
        Assert.Contains("1:02:05", md);
        Assert.True(md.IndexOf("## Summary", StringComparison.Ordinal) < md.IndexOf("## Formatted", StringComparison.Ordinal));
        Assert.Contains("we ship on monday", md);
        var txt = NotesExport.Build(s, NotesExport.Part.Transcript, markdown: false);
        Assert.DoesNotContain("Ship Monday.", txt);
        Assert.Contains("we ship on monday", txt);
    }
}
