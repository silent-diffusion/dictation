using System.Text.Json.Serialization;

namespace Dictation.Core.Notes;

/// <summary>What Extended Notes listens to.</summary>
public enum NotesSource { Mic, Computer, Both }

/// <summary>The four texts of a session, as the four tabs show them (Edited is worked out from the others).</summary>
public enum NoteDoc { Transcript, Formatted, Summary }

/// <summary>A place in a text and the moment of the recording it belongs to.</summary>
public sealed class NoteAnchor
{
    public int Offset { get; set; }
    public double Seconds { get; set; }
}

/// <summary>One formatting step: what had been heard, what the transcript said (the user's edits included) when it was
/// sent to the AI, and what the AI made of it. The Edited tab is built from these.</summary>
public sealed class NoteChunk
{
    public string Heard { get; set; } = "";
    public string Sent { get; set; } = "";
    public string Ai { get; set; } = "";
    public double Seconds { get; set; }
    /// <summary>The AI was unavailable or its output was rejected: <see cref="Ai"/> is the text as sent.</summary>
    public bool AiFailed { get; set; }
}

/// <summary>
/// One Extended Notes session: a lecture or meeting, transcribed as it goes. <see cref="Heard"/> is what the recognizer
/// produced (never changed); <see cref="Transcript"/>, <see cref="Formatted"/> and <see cref="Summary"/> are the texts as
/// the user edited them. Time anchors map text positions to the recording and move with the user's edits. Use from the
/// UI thread.
/// </summary>
public sealed class NoteSession
{
    public string Title { get; set; } = "";
    public DateTime Started { get; set; } = DateTime.Now;
    /// <summary>Seconds recorded (pauses not counted); the length of audio.wav.</summary>
    public double Seconds { get; set; }
    public NotesSource Source { get; set; } = NotesSource.Mic;
    /// <summary>False while recording (and after a crash until the next start, which closes it).</summary>
    public bool Finished { get; set; }

    public string Heard { get; set; } = "";
    public string Transcript { get; set; } = "";
    public string Formatted { get; set; } = "";
    public string Summary { get; set; } = "";

    /// <summary>How much of <see cref="Transcript"/> (and of <see cref="Heard"/>) has been formatted.</summary>
    public int FormattedThrough { get; set; }
    public int HeardFormattedThrough { get; set; }
    /// <summary>How much of <see cref="Formatted"/> the summary covers.</summary>
    public int SummarizedThrough { get; set; }

    public List<NoteChunk> Chunks { get; set; } = new();
    public List<NoteAnchor> TranscriptAnchors { get; set; } = new();
    public List<NoteAnchor> FormattedAnchors { get; set; } = new();

    /// <summary>The session's folder (session.json and audio.wav).</summary>
    [JsonIgnore] public string Folder { get; set; } = "";
    [JsonIgnore] public string AudioPath => Path.Combine(Folder, "audio.wav");
    [JsonIgnore] public string Id => Path.GetFileName(Folder);

    /// <summary>A text changed; the argument is whoever changed it (a text box, or the recorder), so it can skip its own
    /// change.</summary>
    public event Action<NoteDoc, object?>? Changed;

    // Ends of a formatting or summary request still on its way, moved with the user's edits meanwhile; -1 when none.
    [JsonIgnore] int _pendingFormatEnd = -1;
    [JsonIgnore] int _pendingSummaryEnd = -1;

    public string Get(NoteDoc doc) => doc switch
    {
        NoteDoc.Formatted => Formatted,
        NoteDoc.Summary => Summary,
        _ => Transcript,
    };

    /// <summary>A finished piece from the recognizer, at <paramref name="seconds"/> into the recording.</summary>
    public void AppendHeard(string text, double seconds, object? source = null)
    {
        text = text.Trim();
        if (text.Length == 0) return;
        Heard = Join(Heard, text);
        var sep = Transcript.Length == 0 || char.IsWhiteSpace(Transcript[^1]) ? "" : " ";
        TranscriptAnchors.Add(new NoteAnchor { Offset = Transcript.Length + sep.Length, Seconds = seconds });
        Transcript += sep + text;
        Changed?.Invoke(NoteDoc.Transcript, source);
    }

    static string Join(string a, string b) => a.Length == 0 ? b : a + " " + b;

    /// <summary>The user edited a text (in a text box): keep the anchors and the formatting marks in step.</summary>
    public void Set(NoteDoc doc, string text, object? source)
    {
        var old = Get(doc);
        if (old == text) return;
        var (offset, removed, added) = Change(old, text);
        switch (doc)
        {
            case NoteDoc.Transcript:
                Transcript = text;
                Shift(TranscriptAnchors, offset, removed, added);
                FormattedThrough = Move(FormattedThrough, offset, removed, added);
                if (_pendingFormatEnd >= 0) _pendingFormatEnd = Move(_pendingFormatEnd, offset, removed, added);
                break;
            case NoteDoc.Formatted:
                Formatted = text;
                Shift(FormattedAnchors, offset, removed, added);
                SummarizedThrough = Move(SummarizedThrough, offset, removed, added);
                if (_pendingSummaryEnd >= 0) _pendingSummaryEnd = Move(_pendingSummaryEnd, offset, removed, added);
                break;
            default:
                Summary = text;
                break;
        }
        Changed?.Invoke(doc, source);
    }

    /// <summary>The one edit that turns <paramref name="old"/> into <paramref name="now"/>: where, how much went, how much came.</summary>
    public static (int Offset, int Removed, int Added) Change(string old, string now)
    {
        var prefix = 0;
        var max = Math.Min(old.Length, now.Length);
        while (prefix < max && old[prefix] == now[prefix]) prefix++;
        var suffix = 0;
        while (suffix < max - prefix && old[old.Length - 1 - suffix] == now[now.Length - 1 - suffix]) suffix++;
        return (prefix, old.Length - prefix - suffix, now.Length - prefix - suffix);
    }

    /// <summary>Where a position ends up after an edit: before it, it stays; after it, it moves by the change in length;
    /// inside what was removed, it lands at the edit.</summary>
    /// <remarks>For a boundary (how far formatting got): text typed right at it stays after it, so it is formatted next.</remarks>
    public static int Move(int pos, int offset, int removed, int added) =>
        pos <= offset ? pos : pos >= offset + removed ? pos + added - removed : offset + added;

    /// <summary>The same for a time anchor: text typed right at the start of a piece goes before it, so the anchor still
    /// marks where that piece's words begin.</summary>
    public static int MoveAnchor(int pos, int offset, int removed, int added) =>
        pos < offset ? pos : pos >= offset + removed ? pos + added - removed : offset + added;

    static void Shift(List<NoteAnchor> anchors, int offset, int removed, int added)
    {
        foreach (var a in anchors) a.Offset = MoveAnchor(a.Offset, offset, removed, added);
    }

    /// <summary>The moment of the recording that the text at <paramref name="caret"/> was said: the anchor at or before it.</summary>
    public double SecondsAt(NoteDoc doc, int caret)
    {
        var anchors = doc == NoteDoc.Formatted ? FormattedAnchors : TranscriptAnchors;
        double seconds = 0;
        foreach (var a in anchors)
        {
            if (a.Offset > caret) break;
            seconds = a.Seconds;
        }
        return seconds;
    }

    // ===== formatting and summary steps =====

    /// <summary>Words not formatted yet.</summary>
    public int UnformattedWords() => Words(Transcript[Math.Min(FormattedThrough, Transcript.Length)..]);

    public static int Words(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    /// <summary>Take the transcript not formatted yet (to send to the AI); null when there is none.</summary>
    public (string Heard, string Sent, double Seconds)? BeginFormat()
    {
        var from = Math.Min(FormattedThrough, Transcript.Length);
        var sent = Transcript[from..];
        if (sent.Trim().Length == 0) return null;
        _pendingFormatEnd = Transcript.Length;
        var heard = Heard[Math.Min(HeardFormattedThrough, Heard.Length)..];
        HeardFormattedThrough = Heard.Length;
        var seconds = TranscriptAnchors.Where(a => a.Offset >= from).Select(a => a.Seconds).DefaultIfEmpty(Seconds).First();
        return (heard.Trim(), sent.Trim(), seconds);
    }

    /// <summary>The AI's formatting of what <see cref="BeginFormat"/> took: appended to <see cref="Formatted"/>.</summary>
    public void EndFormat(string heard, string sent, string ai, double seconds, bool failed, object? source = null)
    {
        Chunks.Add(new NoteChunk { Heard = heard, Sent = sent, Ai = ai.Trim(), Seconds = seconds, AiFailed = failed });
        FormattedThrough = _pendingFormatEnd >= 0 ? _pendingFormatEnd : Transcript.Length;
        _pendingFormatEnd = -1;
        var sep = Formatted.Length == 0 ? "" : Formatted.EndsWith("\n\n") ? "" : Formatted.EndsWith('\n') ? "\n" : "\n\n";
        FormattedAnchors.Add(new NoteAnchor { Offset = Formatted.Length + sep.Length, Seconds = seconds });
        Formatted += sep + ai.Trim();
        Changed?.Invoke(NoteDoc.Formatted, source);
    }

    /// <summary>Formatted text the summary doesn't cover yet; null when there is none.</summary>
    public string? BeginSummary()
    {
        var from = Math.Min(SummarizedThrough, Formatted.Length);
        var fresh = Formatted[from..];
        if (fresh.Trim().Length == 0) return null;
        _pendingSummaryEnd = Formatted.Length;
        return fresh.Trim();
    }

    /// <summary>The updated summary. Skipped (false) when the user changed the summary meanwhile; the next update starts
    /// from their version.</summary>
    public bool EndSummary(string? summary, string basedOn, object? source = null)
    {
        var end = _pendingSummaryEnd;
        _pendingSummaryEnd = -1;
        if (summary == null || Summary != basedOn) return false;
        SummarizedThrough = end >= 0 ? end : Formatted.Length;
        Summary = summary.Trim();
        Changed?.Invoke(NoteDoc.Summary, source);
        return true;
    }

    /// <summary>A request failed: nothing changes, and the same text is tried again next time.</summary>
    public void CancelSummary() => _pendingSummaryEnd = -1;
}
