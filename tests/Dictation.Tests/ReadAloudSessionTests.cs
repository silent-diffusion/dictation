using Dictation.Core.Reading;
using NAudio.Wave;
using Xunit;

namespace Dictation.Tests;

/// <summary>The playback side of Read aloud, fed the way NAudio's output device feeds it (byte buffers).</summary>
public class ReadAloudSessionTests
{
    // The session never touches the voice engine unless Start() is called.
    static ReadAloudSession Session(string text) => new(text, null!, "af_heart", 1.0);

    static float[] Ramp(int n) => Enumerable.Range(1, n).Select(i => i / (float)n).ToArray();

    const int LeadIn = ReadAloudSession.LeadInSamples;

    /// <summary>Play (and check) the runway of near-silence that comes before speech.</summary>
    static void SkipLeadIn(ReadAloudSession s)
    {
        var runway = new byte[LeadIn * 4];
        s.Read(runway, 0, runway.Length);
        AssertQuiet(Floats(runway, 0, runway.Length));
    }

    /// <summary>Inaudible, but never exact digital silence (which makes some devices fade the next sound in).</summary>
    static void AssertQuiet(float[] samples)
    {
        Assert.All(samples, x => Assert.True(Math.Abs(x) <= 1e-4f));
        Assert.Contains(samples, x => x != 0f);
    }

    static float[] Floats(byte[] bytes, int offset, int count)
    {
        var f = new float[count / 4];
        Buffer.BlockCopy(bytes, offset, f, 0, count);
        return f;
    }

    [Fact]
    public void NAudio_float_view_is_a_byte_array_underneath()
    {
        // Why the session works in bytes: 2.0.0 copied into this view with Array.Copy, which threw on the first
        // sentence, and NAudio silently stopped playback.
        var wb = new WaveBuffer(new byte[7200]);
        Assert.Throws<ArrayTypeMismatchException>(() => Array.Copy(new float[1800], 0, wb.FloatBuffer, 0, 1800));
    }

    [Fact]
    public void Plays_the_sentence_then_silence_and_finishes()
    {
        var s = Session("Hello there.");
        var finished = new ManualResetEventSlim();
        s.Finished += finished.Set;
        var audio = Ramp(1000);
        s.Provide(0, audio, s.Generation, 1.0);
        SkipLeadIn(s);

        var buffer = Enumerable.Repeat((byte)0xFF, 7200).ToArray(); // a dirty device buffer
        Assert.Equal(7200, s.Read(buffer, 0, 7200));

        var played = Floats(buffer, 0, 7200);
        Assert.Equal(audio, played[..1000]);
        AssertQuiet(played[1000..]);
        Assert.True(s.IsEnded);
        Assert.True(finished.Wait(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void Continues_across_reads_and_sentences_at_an_offset()
    {
        var s = Session("One sentence here. And another one.");
        Assert.Equal(2, s.Sentences.Count);
        var first = Ramp(600);
        var second = Ramp(600).Select(x => -x).ToArray();
        s.Provide(0, first, s.Generation, 1.0);
        s.Provide(1, second, s.Generation, 1.0);
        SkipLeadIn(s);

        var buffer = new byte[16 + 800 * 4];
        s.Read(buffer, 16, 800 * 4);
        var a = Floats(buffer, 16, 800 * 4);
        s.Read(buffer, 16, 800 * 4);
        var b = Floats(buffer, 16, 800 * 4);

        // Sentences that are ready follow each other with no runway in between.
        Assert.Equal(first.Concat(second).ToArray(), a.Concat(b).Take(1200).ToArray());
        AssertQuiet(b[400..]);
        Assert.True(s.IsEnded);
    }

    [Fact]
    public void Quiet_while_waiting_for_audio_or_paused()
    {
        var s = Session("Hello there.");
        var buffer = Enumerable.Repeat((byte)0xFF, 400).ToArray();
        Assert.Equal(400, s.Read(buffer, 0, 400));
        AssertQuiet(Floats(buffer, 0, 400));
        Assert.True(s.IsBuffering);

        s.Provide(0, Ramp(100), s.Generation, 1.0);
        s.TogglePause();
        buffer = Enumerable.Repeat((byte)0xFF, 400).ToArray();
        s.Read(buffer, 0, 400);
        AssertQuiet(Floats(buffer, 0, 400));
        Assert.False(s.IsEnded);
    }

    [Fact]
    public void Speech_after_a_wait_gets_the_runway_first()
    {
        var s = Session("One sentence here. And another one.");
        var first = Ramp(200);
        s.Provide(0, first, s.Generation, 1.0);
        SkipLeadIn(s);
        var buffer = new byte[200 * 4];
        s.Read(buffer, 0, buffer.Length);
        Assert.Equal(first, Floats(buffer, 0, buffer.Length));

        // The second sentence isn't ready: the player waits...
        s.Read(new byte[400], 0, 400);
        Assert.True(s.IsBuffering);
        // ...and when it arrives, the runway plays before it, so a device waking up can't eat its first word.
        var second = Ramp(300);
        s.Provide(1, second, s.Generation, 1.0);
        SkipLeadIn(s);
        buffer = new byte[300 * 4];
        s.Read(buffer, 0, buffer.Length);
        Assert.Equal(second, Floats(buffer, 0, buffer.Length));
    }

    [Fact]
    public void Audio_from_before_a_speed_change_is_dropped()
    {
        var s = Session("Hello there.");
        var stale = s.Generation;
        s.SetSpeed(1.5);
        s.Provide(0, Ramp(100), stale, 1.0);
        Assert.True(s.IsBuffering);
    }

    const int Rate = 24000;
    static string Long(char c) => new string(c, 3) + " " + string.Join(" ", Enumerable.Repeat("words that take a while to say", 6)) + ".";

    [Fact]
    public void The_voice_keeps_thirty_seconds_ready_ahead_not_a_fixed_count()
    {
        var s = Session(string.Join(" ", Enumerable.Range(0, 6).Select(i => Long((char)('a' + i)))));
        Assert.Equal(0, s.NextToSynthesizeLocked());
        s.Provide(0, new float[Rate * 5], s.Generation, 1.0);
        s.Provide(1, new float[Rate * 5], s.Generation, 1.0);
        Assert.Equal(2, s.NextToSynthesizeLocked()); // 10 s ready: keep going (it used to stop at two ahead)
        s.Provide(2, new float[Rate * 25], s.Generation, 1.0);
        Assert.Equal(-1, s.NextToSynthesizeLocked()); // 35 s ready: enough
    }

    [Fact]
    public void A_slow_voice_waits_until_enough_is_ready_then_reads_on()
    {
        var s = Session(string.Join(" ", Enumerable.Range(0, 4).Select(i => Long((char)('a' + i)))));
        var first = Ramp(Rate);
        // The voice makes 1 s of audio in 2 s: slower than real time.
        for (var i = 0; i < 6; i++) s.Provide(0, first, s.Generation, 1.0, seconds: 2.0);
        var buffer = new byte[LeadIn * 4 + 4000];
        s.Read(buffer, 0, buffer.Length);
        AssertQuiet(Floats(buffer, 0, buffer.Length)); // 1 s ready of a long reading: not enough to start
        s.Provide(1, new float[Rate * 20], s.Generation, 1.0);
        SkipLeadIn(s);
        var played = new byte[400];
        s.Read(played, 0, played.Length);
        Assert.Equal(first[..100], Floats(played, 0, played.Length)); // enough now: reads on
    }

    [Fact]
    public void A_fast_voice_reads_as_soon_as_the_sentence_is_there()
    {
        var s = Session(string.Join(" ", Enumerable.Range(0, 4).Select(i => Long((char)('a' + i)))));
        var first = Ramp(Rate);
        s.Provide(0, first, s.Generation, 1.0, seconds: 0.3);
        SkipLeadIn(s);
        var played = new byte[400];
        s.Read(played, 0, played.Length);
        Assert.Equal(first[..100], Floats(played, 0, played.Length));
    }
}

public class ReadAloudJumpTests
{
    static float[] Ramp(int n) => Enumerable.Range(1, n).Select(i => i / (float)n).ToArray();

    [Fact]
    public void Jumping_to_a_word_plays_from_there_forwards_and_backwards()
    {
        var s = new ReadAloudSession("One sentence here. And another one.", null!, "af_heart", 1.0);
        var first = Ramp(400);
        var second = Ramp(400).Select(x => -x).ToArray();
        s.Provide(0, first, s.Generation, 1.0);
        s.Provide(1, second, s.Generation, 1.0);

        s.JumpTo(1, 0.5); // forwards: halfway into the second sentence
        Assert.Equal((1, 0.5), s.Position);
        var buffer = new byte[(ReadAloudSession.LeadInSamples + 200) * 4];
        s.Read(buffer, 0, buffer.Length);
        var played = new float[buffer.Length / 4];
        Buffer.BlockCopy(buffer, 0, played, 0, buffer.Length);
        Assert.Equal(second[200..], played[ReadAloudSession.LeadInSamples..]); // after the runway, from the jump point
        Assert.True(s.IsEnded);

        s.JumpTo(0, 0); // backwards, even from the end
        Assert.False(s.IsEnded);
        Assert.Equal((0, 0.0), s.Position);
    }
}
