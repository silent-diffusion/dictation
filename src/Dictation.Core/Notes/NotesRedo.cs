namespace Dictation.Core.Notes;

/// <summary>Redoing a finished session's steps (the pipeline at the top of a session): which step, and how the
/// recording is cut to be transcribed again.</summary>
public static class NotesRedo
{
    /// <summary>What to redo; every step after it is redone too, since it is made from it.</summary>
    public enum Step { Transcribe, Format, Summary }

    /// <summary>About how long each part sent to the speech engine is: like the pieces of a live session.</summary>
    public const double PartSeconds = 15;

    /// <summary>The recording cut into parts of about <paramref name="target"/> seconds, each cut in the pause nearest
    /// to that point (so no word is split), or at the point itself when there is no pause near it.</summary>
    public static List<(double Start, double End)> PlanParts(double seconds, IReadOnlyList<AudioPause> pauses, double target = PartSeconds)
    {
        var parts = new List<(double Start, double End)>();
        var start = 0.0;
        while (seconds - start > target + 8)
        {
            var want = start + target;
            var cut = pauses.Select(p => (p.Start + p.End) / 2)
                .Where(m => m > want - 6 && m < want + 8)
                .OrderBy(m => Math.Abs(m - want))
                .DefaultIfEmpty(want).First();
            parts.Add((start, cut));
            start = cut;
        }
        if (seconds - start > 0.3) parts.Add((start, seconds));
        return parts;
    }
}
