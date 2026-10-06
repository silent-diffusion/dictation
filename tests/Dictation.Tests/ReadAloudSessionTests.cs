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
}
