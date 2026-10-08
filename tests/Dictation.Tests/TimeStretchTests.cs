using Dictation.Core.Speech;
using Xunit;

namespace Dictation.Tests;

public class TimeStretchTests
{
    static float[] Tone(double hz, int samples) =>
        Enumerable.Range(0, samples).Select(i => (float)Math.Sin(2 * Math.PI * hz * i / 24000)).ToArray();

    static int Crossings(float[] a, int from, int to)
    {
        var n = 0;
        for (var i = from + 1; i < to; i++) if (a[i - 1] < 0 && a[i] >= 0) n++;
        return n;
    }

    [Theory]
    [InlineData(0.25)]
    [InlineData(0.5)]
    [InlineData(2.0)]
    [InlineData(4.0)]
    public void Changes_the_length_but_not_the_pitch(double factor)
    {
        var tone = Tone(220, 24000 * 2);
        var stretched = TimeStretch.Apply(tone, factor);
        Assert.Equal((int)(tone.Length / factor), stretched.Length);
        // A quarter second from the middle still holds 220 Hz: about 55 upward zero crossings.
        var mid = stretched.Length / 2;
        Assert.InRange(Crossings(stretched, mid - 3000, mid + 3000), 53, 57);
        Assert.InRange(stretched.Max(), 0.8f, 1.1f);
    }

    [Fact]
    public void Leaves_normal_speed_alone()
    {
        var tone = Tone(220, 24000);
        Assert.Same(tone, TimeStretch.Apply(tone, 1.0));
    }
}
