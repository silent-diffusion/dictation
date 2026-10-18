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
    public void Sections_are_taken_in_order_and_the_summary_keeps_the_users_edit()
    {
        var s = new NoteSession();
        s.AppendHeard("words", 0);
        var take = s.BeginFormat()!.Value;
        s.EndFormat(take.Heard, take.Sent, "Words.", 0, false);
        var section = s.BeginSection(NotesSummary.InputBudget)!.Value;
        Assert.Equal("Words.", section.Text);
        s.EndSection(null, section.Start, section.End); // the AI failed: still to do
        Assert.Equal("Words.", s.BeginSection(NotesSummary.InputBudget)!.Value.Text);
        s.EndSection("One word.", section.Start, section.End);
        Assert.Null(s.BeginSection(NotesSummary.InputBudget));
        Assert.Single(s.Frontier());

        s.Set(NoteDoc.Summary, "Mine", null);
        Assert.False(s.EndSummary("AI summary", basedOn: "")); // edited meanwhile
        Assert.Equal("Mine", s.Summary);
        Assert.True(s.EndSummary("AI summary", basedOn: "Mine"));
        Assert.Equal("AI summary", s.SummaryByAi);
    }

    [Fact]
    public void Merged_digests_leave_the_frontier_and_cover_their_parts()
    {
        var s = new NoteSession();
        for (var i = 0; i < 4; i++)
        {
            s.Formatted += $"Part {i}. ";
            Assert.NotNull(s.BeginSection(8));
            s.EndSection($"D{i}", i * 60, (i + 1) * 60);
        }
        Assert.Equal(4, s.Frontier().Count);
        var group = NotesSummary.MergeGroup(s.Frontier());
        Assert.NotNull(group);
        s.Merge(group!, "D0-3");
        var left = s.Frontier();
        Assert.Single(left);
        Assert.Equal((1, 0, 3, 0.0, 240.0), (left[0].Level, left[0].First, left[0].Last, left[0].Start, left[0].End));
    }

    [Fact]
    public void A_position_in_the_formatted_text_maps_to_its_share_of_the_step()
    {
        var s = new NoteSession();
        s.AppendHeard("one two three four", 10);
        s.AppendHeard("five six", 70);
        var take = s.BeginFormat()!.Value;
        s.EndFormat(take.Heard, take.Sent, "One two three four five six.", take.Seconds, false);
        s.Seconds = 130;
        Assert.Equal(10, s.SecondsAt(NoteDoc.Formatted, 0), 3);
        Assert.InRange(s.SecondsAt(NoteDoc.Formatted, s.Formatted.Length / 2), 60, 80);
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

public class NotesSummaryTests
{
    [Fact]
    public void A_section_ends_at_a_paragraph_or_sentence_within_the_budget()
    {
        var text = "First sentence here.\nSecond one here. Third one is longer than the rest of them.";
        Assert.Equal(text.Length, NotesSummary.SectionEnd(text, 0, 500));
        Assert.Equal(21, NotesSummary.SectionEnd(text, 0, 30)); // at the line break
        Assert.Equal(37, NotesSummary.SectionEnd(text, 0, 45)); // at the end of a sentence
    }

    [Fact]
    public void The_summary_is_shaped_into_main_idea_points_and_paragraphs()
    {
        var raw = "**Summary**\nMain idea: The launch moves to May.\n\n- Budget approved\n- Hiring paused\n- QA needs two weeks\n- Extra point\n\n" +
                  "First para.\n\nSecond para.\n\nThird para.\n\nFourth para.";
        var shaped = NotesSummary.Shape(raw)!;
        Assert.StartsWith("Main idea: The launch moves to May.", shaped);
        Assert.Equal(3, shaped.Split('\n').Count(l => l.StartsWith("- ")));
        Assert.DoesNotContain("Extra point", shaped);
        Assert.DoesNotContain("**", shaped);
        Assert.DoesNotContain("Summary\n", shaped);
        Assert.EndsWith("Third para. Fourth para.", shaped);
        Assert.Equal(5, shaped.Split("\n\n").Length); // the main idea, the points, three paragraphs

        var plain = NotesSummary.Shape("The team met about the launch. Dates were discussed at length.\n\nBudget is fine.")!;
        Assert.StartsWith("Main idea: The team met about the launch.", plain);
        Assert.Contains("Dates were discussed at length.", plain);
        Assert.Null(NotesSummary.Shape("..."));
    }

    [Fact]
    public void Four_digests_of_a_level_merge_and_an_oversized_frontier_merges_its_oldest()
    {
        static NoteDigest D(int n, int level, int chars) => new() { Level = level, First = n, Last = n, Text = new string('x', chars) };
        Assert.Null(NotesSummary.MergeGroup(new[] { D(0, 0, 100), D(1, 0, 100), D(2, 0, 100) }));
        var four = new[] { D(0, 0, 100), D(1, 0, 100), D(2, 0, 100), D(3, 0, 100) };
        Assert.Equal(four, NotesSummary.MergeGroup(four)!);
        var mixed = new[] { D(0, 1, 100), D(1, 0, 100), D(2, 0, 100), D(3, 0, 100), D(4, 0, 100) };
        Assert.Equal(mixed.Skip(1), NotesSummary.MergeGroup(mixed)!);
        var big = new[] { D(0, 1, NotesSummary.FrontierBudget / 2), D(1, 2, NotesSummary.FrontierBudget / 2), D(2, 0, 100) };
        Assert.Equal(big.Take(2), NotesSummary.MergeGroup(big)!);
    }

    [Fact]
    public void A_usable_digest_has_words_and_is_shorter_than_its_source()
    {
        var source = string.Join(" ", Enumerable.Repeat("word", 200));
        Assert.True(NotesSummary.IsUsable(source, "A short summary of it all."));
        Assert.False(NotesSummary.IsUsable(source, "..."));
        Assert.False(NotesSummary.IsUsable(source, source + " and more"));
        Assert.True(NotesSummary.InputBudget > 6000);
    }
}

public class NotesPlaybackTests
{
    [Fact]
    public void Quiet_speech_is_brought_up_and_its_pauses_found()
    {
        var dir = System.IO.Directory.CreateTempSubdirectory("oberton-notes-test");
        try
        {
            var src = System.IO.Path.Combine(dir.FullName, "audio.wav");
            const int rate = 16000;
            using (var w = new WaveFileWriter(src, new WaveFormat(rate, 16, 1)))
            {
                // A second of quiet speech, two seconds of near-silence, a second of quiet speech.
                var samples = new short[rate * 4];
                for (var i = 0; i < samples.Length; i++)
                {
                    var t = i / (double)rate;
                    var speaking = t < 1 || t >= 3;
                    var v = speaking ? 0.02 * Math.Sin(2 * Math.PI * 220 * t) : 0.0002 * Math.Sin(2 * Math.PI * 50 * t);
                    samples[i] = (short)(v * 32767);
                }
                w.WriteSamples(samples, 0, samples.Length);
            }
            var prepared = NotesAudio.Prepare(src, System.IO.Path.Combine(dir.FullName, "play.wav"));
            Assert.InRange(prepared.GainDb, 30, 34); // 0.02 up to 0.89 is +33 dB
            Assert.InRange(prepared.Seconds, 3.99, 4.01);
            var gap = Assert.Single(prepared.Silences);
            Assert.InRange(gap.Start, 0.9, 1.2);
            Assert.InRange(gap.End, 2.8, 3.1);
            Assert.NotNull(prepared.SilenceAt(2.0));
            Assert.Null(prepared.SilenceAt(0.5));

            using var r = new WaveFileReader(prepared.Path);
            var sp = r.ToSampleProvider();
            var buf = new float[rate];
            var peak = 0f;
            int n;
            while ((n = sp.Read(buf, 0, buf.Length)) > 0)
                for (var i = 0; i < n; i++) peak = Math.Max(peak, Math.Abs(buf[i]));
            Assert.InRange(peak, 0.85f, 0.95f);
        }
        finally { dir.Delete(true); }
    }

    [Fact]
    public void The_prepared_copy_is_kept_for_the_next_time()
    {
        var dir = System.IO.Directory.CreateTempSubdirectory("oberton-notes-test");
        var id = "test-" + Guid.NewGuid().ToString("N");
        try
        {
            var src = System.IO.Path.Combine(dir.FullName, "audio.wav");
            using (var w = new WaveFileWriter(src, new WaveFormat(16000, 16, 1))) w.WriteSamples(new short[16000], 0, 16000);
            var first = NotesAudio.PrepareCached(src, id);
            var again = NotesAudio.PrepareCached(src, id);
            Assert.Equal(first.Path, again.Path);
            Assert.True(System.IO.File.Exists(again.Path));
            Assert.InRange(again.Seconds, 0.99, 1.01);
            NotesAudio.Forget(id);
            Assert.False(System.IO.File.Exists(first.Path));
        }
        finally { dir.Delete(true); NotesAudio.Forget(id); }
    }

    [Fact]
    public void Gain_never_lowers_and_never_exceeds_the_cap()
    {
        Assert.Equal(1f, NotesAudio.Gain(new[] { 0.95f, 0.9f, 0.99f }));
        Assert.Equal(100f, NotesAudio.Gain(new[] { 0.001f, 0.001f }), 1); // capped at +40 dB
        Assert.Equal(1f, NotesAudio.Gain(new[] { 0.0001f, 0.0001f })); // silence: nothing to bring up
        Assert.Equal(1f, NotesAudio.Gain(Array.Empty<float>()));
    }

    [Fact]
    public void Edited_pieces_carry_the_moment_they_were_said()
    {
        var s = new NoteSession();
        s.AppendHeard("hello there", 5);
        var t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, "Hello there.", t.Seconds, false);
        s.AppendHeard("later words", 40);
        s.Seconds = 60;
        var pieces = NotesEdits.Build(s);
        Assert.Equal(5, pieces[0].Seconds, 3);
        Assert.Equal(40, pieces[^1].Seconds, 3);
    }
}

public class NotesUsageTests
{
    [Fact]
    public void A_finished_session_is_counted_on_its_day_apart_from_dictation()
    {
        var usage = new NotesUsage(null);
        var s = new NoteSession
        {
            Started = new DateTime(2026, 10, 17, 9, 0, 0), Seconds = 3600, Source = NotesSource.Both,
            Heard = "one two three", Transcript = "one two three my note",
        };
        usage.Record(s, formatRequests: 12, summaryRequests: 4);
        usage.Record(new NoteSession { Started = new DateTime(2026, 10, 17, 14, 0, 0), Seconds = 60 }, 1, 0);
        var day = Assert.Single(usage.Days);
        Assert.Equal((2, 3660.0, 3, 2, 13, 4), (day.Sessions, day.Seconds, day.WordsHeard, day.WordsTyped, day.FormatRequests, day.SummaryRequests));
        Assert.Equal(1, day.Sources["Both"]);
        Assert.Equal(1, day.Sources["Mic"]);
    }
}

public class NotesFormatTests
{
    [Fact]
    public void A_reply_that_runs_on_past_the_text_is_cut_back_to_it()
    {
        const string sent = "We visited two families. We talked about the budget.";
        var reply = "We visited two families. We talked about the budget.  \n\n⚠️ 00:03:15  \n⚠️ 00:03:16  \n⌋  \n⏸️  \n☑ 00:00:02\n璩  \n璩";
        Assert.Equal(sent, NotesFormat.Accept(sent, reply));
    }

    [Fact]
    public void Loops_are_collapsed_but_a_sentence_said_twice_stays()
    {
        Assert.Equal("Hello. Thank you. Bye.", NotesFormat.CollapseRepeats("Hello. Thank you. Thank you. Thank you. Thank you. Bye."));
        Assert.Equal("Thank you. Thank you. Bye.", NotesFormat.CollapseRepeats("Thank you. Thank you. Bye."));
        Assert.Equal("Thank you.\nThank you.\nThank you.", NotesFormat.CollapseRepeats("Thank you.\nThank you.\nThank you.")); // lines stay
    }

    [Fact]
    public void A_reply_that_adds_words_or_changes_a_number_is_rejected()
    {
        const string sent = "it is north of lowes on 4th east and 1550 north at 3 on saturday";
        Assert.Null(NotesFormat.Accept(sent, "It is north of Lowe's, on 4th East and 155-0 North, at 3 on Saturday."));
        Assert.Null(NotesFormat.Accept(sent, "It is north of Lowe's on 4th East and 1550 North at 3 on Saturday, and everyone should bring a dish and a friend along to the event."));
        Assert.Null(NotesFormat.Accept(sent, "North."));
        Assert.Equal("It is north of Lowe's, on 4th East and 1550 North, at 3 on Saturday.",
            NotesFormat.Accept(sent, "It is north of Lowe's, on 4th East and 1550 North, at 3 on Saturday."));
    }

    [Fact]
    public void Labels_no_one_said_and_split_lines_are_undone()
    {
        Assert.Equal("You need to go on the state in volleyball.",
            NotesFormat.Accept("you need to go on the state in volleyball", "⚠️ listener note: You need to go on the state in volleyball."));
        Assert.Equal("Thank you. What are you going to think about it?",
            NotesFormat.Accept("thank you what are you going to think about it", "Thank you.  \nWhat are you going to think about it?"));
        Assert.Equal("Todo: buy milk", NotesFormat.Accept("Todo: buy milk", "Todo: buy milk")); // a label in the text stays
    }

    [Fact]
    public void Markers_stay_lost_ones_come_back_and_made_up_ones_go()
    {
        const string sent = "Hello there.\n⚑ 1:23\nMore words here.";
        Assert.Equal(sent, NotesFormat.Accept(sent, sent));
        Assert.Equal("Hello there.\nMore words here.\n⚑ 1:23", NotesFormat.Accept(sent, "Hello there.\nMore words here."));
        Assert.Equal(sent, NotesFormat.Accept(sent, "Hello there.\n⚑ 1:23\n⚑ 9:59\nMore words here."));
    }

    [Fact]
    public void The_reply_limit_follows_the_text()
    {
        Assert.InRange(NotesFormat.MaxTokens(new string('a', 600)), 240, 260);
        Assert.InRange(NotesFormat.MaxTokens(new string('会', 600)), 640, 660);
    }

    [Fact]
    public void A_session_formatted_before_the_checks_is_repaired_with_its_anchors()
    {
        var s = new NoteSession();
        s.AppendHeard("first part of the talk", 0);
        var t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, "First part of the talk.  \n\n⚠️ 00:03:15  \n⚠️ 00:03:16", t.Seconds, false);
        s.AppendHeard("second part", 60);
        t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, "Second part. Thank you. Thank you. Thank you.  \n璩  \n璩", t.Seconds, false);
        s.SummarizedThrough = s.Formatted.Length;

        Assert.True(NotesFormat.Repair(s));
        Assert.Equal("First part of the talk.\n\nSecond part. Thank you.", s.Formatted);
        Assert.Equal(s.Formatted.IndexOf("Second", StringComparison.Ordinal), s.FormattedAnchors[1].Offset);
        Assert.Equal(s.Formatted.Length, s.SummarizedThrough);
        Assert.Equal("First part of the talk.", s.Chunks[0].Ai);
        Assert.Equal("Second part. Thank you.", s.Chunks[1].Ai);
        Assert.False(NotesFormat.Repair(s)); // once is enough
    }

    [Fact]
    public void A_part_that_carries_on_a_sentence_joins_it()
    {
        var s = new NoteSession();
        s.AppendHeard("and so", 0);
        var t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, "And so,", t.Seconds, false);
        s.AppendHeard("we went home", 10);
        t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, "we went home.", t.Seconds, false);
        s.AppendHeard("Next topic", 20);
        t = s.BeginFormat()!.Value;
        s.EndFormat(t.Heard, t.Sent, "Next topic.", t.Seconds, false);
        Assert.Equal("And so, we went home.\n\nNext topic.", s.Formatted);
    }

    [Fact]
    public void A_labelled_summary_paragraph_loses_its_label()
    {
        var shaped = NotesSummary.Shape("Main idea: Plans.\n\n- A\n- B\n- C\n\nWhat was decided: We meet weekly outside the library.")!;
        Assert.EndsWith("\n\nWe meet weekly outside the library.", shaped);
    }
}
