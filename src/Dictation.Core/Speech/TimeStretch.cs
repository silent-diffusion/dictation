namespace Dictation.Core.Speech;

/// <summary>
/// Speeds audio up or slows it down without changing the pitch (WSOLA: 40 ms windows overlap-added,
/// each nudged to where it lines up best with the last so voices don't warble). The same algorithm the
/// voice server uses past the 0.5×–2× its voices pace naturally.
/// </summary>
public static class TimeStretch
{
    const int Window = 960, Hop = Window / 2, Tolerance = Hop / 2;

    /// <param name="factor">2 plays twice as fast, 0.5 half as fast.</param>
    public static float[] Apply(float[] audio, double factor)
    {
        if (Math.Abs(factor - 1) < 0.01 || audio.Length < Window * 2) return audio;
        var outLength = (int)(audio.Length / factor);
        var frames = outLength / Hop + 1;
        var x = new float[Tolerance + audio.Length + Window * 2 + (int)(Hop * factor) + Tolerance * 2];
        Array.Copy(audio, 0, x, Tolerance, audio.Length);
        var win = new double[Window];
        for (var i = 0; i < Window; i++) win[i] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / Window);

        var y = new double[frames * Hop + Window];
        var weight = new double[y.Length];
        var prev = Tolerance;
        for (var k = 0; k < frames; k++)
        {
            var nominal = (int)(k * Hop * factor) + Tolerance;
            var pos = nominal;
            if (k > 0)
            {
                var target = prev + Hop;
                var best = double.NegativeInfinity;
                for (var lag = nominal - Tolerance; lag <= nominal + Tolerance; lag++)
                {
                    double sum = 0;
                    for (var i = 0; i < Window; i += 2) sum += x[lag + i] * x[target + i]; // every other sample is plenty
                    if (sum > best) { best = sum; pos = lag; }
                }
            }
            for (var i = 0; i < Window; i++)
            {
                y[k * Hop + i] += x[pos + i] * win[i];
                weight[k * Hop + i] += win[i];
            }
            prev = pos;
        }

        var result = new float[outLength];
        for (var i = 0; i < outLength; i++) result[i] = (float)(y[i] / Math.Max(weight[i], 1e-3));
        return result;
    }
}
