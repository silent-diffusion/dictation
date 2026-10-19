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
    /// <summary>Where the piece begins in <see cref="NoteSession.Heard"/> (transcript anchors; null in sessions from
    /// before 5.5 and for markers), so a part of the transcript can be lined up with what was heard.</summary>
    public int? HeardOffset { get; set; }
}

/// <summary>A moment the listener marked (the marker hotkey or the Mark button) while the session recorded. The
/// transcript has a line for it: <see cref="NoteSession.MarkerFlag"/> and <see cref="Label"/>.</summary>
public sealed class NoteMarker
{
    public double Seconds { get; set; }
    /// <summary>The time as its line shows it: 12:34, or 1:02:03 once there are hours.</summary>
    public string Label { get; set; } = "";
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

/// <summary>A summary of part of the session, kept in the background. Level 0 sums up a section of the formatted text
/// (5 to 10 minutes of speech); a higher level sums up several consecutive summaries, each shorter than what it covers.
/// The Summary tab is written from the ones not folded into a higher level.</summary>
public sealed class NoteDigest
{
    public int Level { get; set; }
    /// <summary>The sections it covers, numbered in order (a level 0 digest covers one).</summary>
    public int First { get; set; }
    public int Last { get; set; }
    /// <summary>The part of the recording it covers, in seconds.</summary>
    public double Start { get; set; }
    public double End { get; set; }
    public string Text { get; set; } = "";
    /// <summary>Folded into a higher-level digest.</summary>
    public bool Merged { get; set; }
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
    /// <summary>The formatting checks it was made (or last repaired) with: older sessions are repaired once when
    /// loaded (<see cref="NotesFormat.Repair"/>).</summary>
    public int FormatVersion { get; set; }

    public string Heard { get; set; } = "";
    public string Transcript { get; set; } = "";
    public string Formatted { get; set; } = "";
    public string Summary { get; set; } = "";

    /// <summary>How much of <see cref="Transcript"/> (and of <see cref="Heard"/>) has been formatted.</summary>
    public int FormattedThrough { get; set; }
    public int HeardFormattedThrough { get; set; }
    /// <summary>How much of <see cref="Formatted"/> the section summaries cover.</summary>
    public int SummarizedThrough { get; set; }
    /// <summary>The summaries of the parts (see <see cref="NoteDigest"/>).</summary>
    public List<NoteDigest> Digests { get; set; } = new();
    /// <summary>The summary as the AI last wrote it: when <see cref="Summary"/> differs, the user edited it, and the
    /// next summary keeps their changes.</summary>
    public string SummaryByAi { get; set; } = "";

    public List<NoteChunk> Chunks { get; set; } = new();
    public List<NoteAnchor> TranscriptAnchors { get; set; } = new();
    public List<NoteAnchor> FormattedAnchors { get; set; } = new();
    /// <summary>The moments the listener marked, in order (see <see cref="AddMarker"/>).</summary>
    public List<NoteMarker> Markers { get; set; } = new();

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
        var heardAt = Heard.Length == 0 ? 0 : Heard.Length + 1;
        Heard = Join(Heard, text);
        var sep = Transcript.Length == 0 || char.IsWhiteSpace(Transcript[^1]) ? "" : " ";
        TranscriptAnchors.Add(new NoteAnchor { Offset = Transcript.Length + sep.Length, Seconds = seconds, HeardOffset = heardAt });
        Transcript += sep + text;
        Changed?.Invoke(NoteDoc.Transcript, source);
    }

    static string Join(string a, string b) => a.Length == 0 ? b : a + " " + b;

    /// <summary>Begins a marker's line in the transcript (the AI is told to keep such lines as they are).</summary>
    public const string MarkerFlag = "⚑";

    /// <summary>A marker's time as its line shows it: m:ss, with the hours once there are any (12:34; 1:02:03).</summary>
    public static string MarkerLabel(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
    }

    /// <summary>The listener marked <paramref name="seconds"/> into the recording: a "⚑ h:mm:ss" line of its own goes
    /// on the end of the transcript (the next piece heard begins a new line), with an anchor so a right-click on it jumps
    /// there. Like <see cref="AppendHeard"/> it only appends, so how far formatting got, and the end of a request on its
    /// way, stay where they are.</summary>
    public void AddMarker(double seconds, object? source = null)
    {
        AppendMarkerLine(seconds);
        Markers.Add(new NoteMarker { Seconds = seconds, Label = MarkerLabel(seconds) });
        Changed?.Invoke(NoteDoc.Transcript, source);
    }

    void AppendMarkerLine(double seconds)
    {
        var sep = Transcript.Length == 0 || Transcript.EndsWith('\n') ? "" : "\n";
        TranscriptAnchors.Add(new NoteAnchor { Offset = Transcript.Length + sep.Length, Seconds = seconds });
        Transcript += sep + MarkerFlag + " " + MarkerLabel(seconds) + "\n";
    }

    // ===== redoing a step (a finished session) =====

    /// <summary>A new transcript, from the recording transcribed again: these pieces, with the markers back in place by
    /// their time. What was formatted and summed up goes with the old one.</summary>
    public void ReplaceTranscript(IReadOnlyList<(double Seconds, string Text)> pieces, object? source = null)
    {
        Heard = "";
        Transcript = "";
        TranscriptAnchors.Clear();
        ResetFormatting(source);
        var markers = Markers.OrderBy(m => m.Seconds).ToList();
        var next = 0;
        foreach (var (seconds, text) in pieces.OrderBy(p => p.Seconds))
        {
            while (next < markers.Count && markers[next].Seconds <= seconds) AppendMarkerLine(markers[next++].Seconds);
            AppendHeard(text, seconds);
        }
        while (next < markers.Count) AppendMarkerLine(markers[next++].Seconds);
        Changed?.Invoke(NoteDoc.Transcript, source);
    }

    /// <summary>Formatting from scratch: the Formatted text, its steps and the summary go.</summary>
    public void ResetFormatting(object? source = null)
    {
        Formatted = "";
        Chunks.Clear();
        FormattedAnchors.Clear();
        FormattedThrough = 0;
        HeardFormattedThrough = 0;
        _pendingFormatEnd = -1;
        ResetSummary(source);
        Changed?.Invoke(NoteDoc.Formatted, source);
    }

    /// <summary>Summing up from scratch.</summary>
    public void ResetSummary(object? source = null)
    {
        Digests.Clear();
        SummarizedThrough = 0;
        Summary = "";
        SummaryByAi = "";
        _pendingSummaryEnd = -1;
        Changed?.Invoke(NoteDoc.Summary, source);
    }

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

    /// <summary>The moment of the recording that the text at <paramref name="caret"/> was said. In the transcript, the
    /// start of the piece it is in (pieces are a few seconds long). In the formatted text, where each AI step covers a
    /// minute or so, the position within that step, in proportion.</summary>
    public double SecondsAt(NoteDoc doc, int caret)
    {
        if (doc != NoteDoc.Formatted)
        {
            double seconds = 0;
            foreach (var a in TranscriptAnchors)
            {
                if (a.Offset > caret) break;
                seconds = a.Seconds;
            }
            return seconds;
        }
        NoteAnchor? at = null, next = null;
        foreach (var a in FormattedAnchors)
        {
            if (a.Offset <= caret) at = a;
            else { next = a; break; }
        }
        if (at == null) return next?.Seconds ?? 0;
        var endOffset = next?.Offset ?? Formatted.Length;
        var endSeconds = next?.Seconds ?? FormattedEndSeconds();
        if (endOffset <= at.Offset || endSeconds <= at.Seconds) return at.Seconds;
        var f = Math.Clamp((caret - at.Offset) / (double)(endOffset - at.Offset), 0, 1);
        return at.Seconds + f * (endSeconds - at.Seconds);
    }

    /// <summary>Where the formatted text ends in the recording: where the transcript not formatted yet begins.</summary>
    public double FormattedEndSeconds() =>
        TranscriptAnchors.FirstOrDefault(a => a.Offset >= FormattedThrough)?.Seconds ?? Seconds;

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

    /// <summary>Like <see cref="BeginFormat"/>, but at most about <paramref name="maxWords"/> words, ending where a
    /// piece ends (at the end of a sentence if one does), for formatting a whole transcript again part by part.</summary>
    public (string Heard, string Sent, double Seconds)? BeginFormatPart(int maxWords)
    {
        var from = Math.Min(FormattedThrough, Transcript.Length);
        if (Transcript[from..].Trim().Length == 0) return null;
        NoteAnchor? any = null, sentence = null, first = null;
        foreach (var a in TranscriptAnchors.Where(a => a.Offset > from && a.Offset <= Transcript.Length).OrderBy(a => a.Offset))
        {
            var words = Words(Transcript[from..a.Offset]);
            if (words == 0) continue;
            first ??= a;
            if (words > maxWords) break;
            any = a;
            var before = Transcript[..a.Offset].TrimEnd();
            var lastLine = before[(before.LastIndexOf('\n') + 1)..].TrimStart();
            if (before.Length > 0 && (before[^1] is '.' or '!' or '?' or '"' or '”' || lastLine.StartsWith(MarkerFlag, StringComparison.Ordinal))) sentence = a;
        }
        // All the rest when it fits; otherwise to a sentence's end, else a piece's; a first piece longer than the limit whole.
        var cut = Words(Transcript[from..]) <= maxWords ? null : sentence ?? any ?? first;
        var end = cut?.Offset ?? Transcript.Length;
        var sent = Transcript[from..end];
        _pendingFormatEnd = end;
        var heardFrom = Math.Min(HeardFormattedThrough, Heard.Length);
        string heard;
        if (cut == null) { heard = Heard[heardFrom..]; HeardFormattedThrough = Heard.Length; }
        else if (cut.HeardOffset is { } h && h >= heardFrom && h <= Heard.Length) { heard = Heard[heardFrom..h]; HeardFormattedThrough = h; }
        else heard = sent; // a session from before heard offsets: the part counts as heard
        var seconds = TranscriptAnchors.Where(a => a.Offset >= from).Select(a => a.Seconds).DefaultIfEmpty(Seconds).First();
        return (heard.Trim(), sent.Trim(), seconds);
    }

    /// <summary>The AI's formatting of what <see cref="BeginFormat"/> took: appended to <see cref="Formatted"/>.</summary>
    public void EndFormat(string heard, string sent, string ai, double seconds, bool failed, object? source = null)
    {
        Chunks.Add(new NoteChunk { Heard = heard, Sent = sent, Ai = ai.Trim(), Seconds = seconds, AiFailed = failed });
        FormattedThrough = _pendingFormatEnd >= 0 ? _pendingFormatEnd : Transcript.Length;
        _pendingFormatEnd = -1;
        ai = ai.Trim();
        // A part that carries on a sentence the last one left open joins it; otherwise it starts a paragraph.
        var continues = Formatted.Length > 0 && ai.Length > 0 && char.IsLower(ai[0]) &&
                        (char.IsLetterOrDigit(Formatted[^1]) || Formatted[^1] == ',');
        var sep = Formatted.Length == 0 ? "" : continues ? " " : Formatted.EndsWith("\n\n") ? "" : Formatted.EndsWith('\n') ? "\n" : "\n\n";
        FormattedAnchors.Add(new NoteAnchor { Offset = Formatted.Length + sep.Length, Seconds = seconds });
        Formatted += sep + ai;
        Changed?.Invoke(NoteDoc.Formatted, source);
    }

    /// <summary>Formatted text no section summary covers yet.</summary>
    public int UnsummarizedChars() => Formatted.Length - Math.Min(SummarizedThrough, Formatted.Length);

    /// <summary>The next section to summarize: the formatted text not covered yet, at most <paramref name="maxChars"/>
    /// (cut at a paragraph or sentence), with the part of the recording it covers; null when there is none.</summary>
    public (string Text, double Start, double End)? BeginSection(int maxChars)
    {
        var from = Math.Min(SummarizedThrough, Formatted.Length);
        var end = NotesSummary.SectionEnd(Formatted, from, maxChars);
        var text = Formatted[from..end];
        if (text.Trim().Length == 0) return null;
        _pendingSummaryEnd = end;
        var start = SecondsAt(NoteDoc.Formatted, from);
        var stop = end >= Formatted.Length ? FormattedEndSeconds() : SecondsAt(NoteDoc.Formatted, end);
        return (text.Trim(), start, Math.Max(start, stop));
    }

    /// <summary>The summary of what <see cref="BeginSection"/> took; null when it failed (the same text is tried again
    /// next time).</summary>
    public void EndSection(string? digest, double start, double end)
    {
        var through = _pendingSummaryEnd;
        _pendingSummaryEnd = -1;
        if (digest == null || digest.Trim().Length == 0) return;
        var number = Digests.Count(d => d.Level == 0);
        Digests.Add(new NoteDigest { Level = 0, First = number, Last = number, Start = start, End = end, Text = digest.Trim() });
        SummarizedThrough = through >= 0 ? through : Formatted.Length;
    }

    /// <summary>The digests not folded into a higher level, in order: together they cover everything summarized.</summary>
    public List<NoteDigest> Frontier() => Digests.Where(d => !d.Merged).OrderBy(d => d.First).ToList();

    /// <summary>Several consecutive digests summed up in one, a level up.</summary>
    public void Merge(IReadOnlyList<NoteDigest> parts, string text)
    {
        foreach (var p in parts) p.Merged = true;
        Digests.Add(new NoteDigest
        {
            Level = parts.Max(p => p.Level) + 1, First = parts.Min(p => p.First), Last = parts.Max(p => p.Last),
            Start = parts.Min(p => p.Start), End = parts.Max(p => p.End), Text = text.Trim(),
        });
    }

    /// <summary>The new summary for the Summary tab. Skipped (false) when the user changed the summary meanwhile; the
    /// next one keeps their version.</summary>
    public bool EndSummary(string summary, string basedOn, object? source = null)
    {
        if (Summary != basedOn || summary.Trim().Length == 0) return false;
        Summary = SummaryByAi = summary.Trim();
        Changed?.Invoke(NoteDoc.Summary, source);
        return true;
    }
}
