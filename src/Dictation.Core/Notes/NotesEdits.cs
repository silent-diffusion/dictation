using System.Text.RegularExpressions;
using Dictation.Core.Text;

namespace Dictation.Core.Notes;

/// <summary>How a word shows on the Edited tab.</summary>
public enum EditMark
{
    /// <summary>As heard, unchanged.</summary>
    Plain,
    /// <summary>A paragraph break that was already there.</summary>
    Paragraph,
    AiRemoved,
    AiAdded,
    /// <summary>A paragraph break the AI made.</summary>
    AiParagraph,
    UserRemoved,
    /// <summary>A word the user put in place of another.</summary>
    UserChanged,
    /// <summary>Words the user typed (a note).</summary>
    UserNote,
}

public readonly record struct EditPiece(string Text, EditMark Mark);

/// <summary>
/// The Edited tab: one text in which every change is marked, the AI's apart from the user's. For each formatting step it
/// lines up what was heard, the transcript as sent (the user's edits) and the AI's output; then the user's edits in the
/// Formatted tab; then the part of the transcript not formatted yet.
/// </summary>
public static class NotesEdits
{
    public const string Para = "¶";
    static readonly Regex Breaks = new(@"\s*\n\s*", RegexOptions.Compiled);

    /// <summary>Words, with each line or paragraph break as a <see cref="Para"/> token.</summary>
    public static string[] Tokens(string text) =>
        LongDiff.Split(Breaks.Replace(text.Trim(), " " + Para + " "));

    // One word on its way through the merge: its text, mark, and whether it is part of the AI's text (A).
    record struct Item(string Text, EditMark Mark, bool InAi, bool UserOrigin);

    public static IReadOnlyList<EditPiece> Build(NoteSession s)
    {
        var items = new List<Item>();
        var aiTokens = new List<string>();
        foreach (var chunk in s.Chunks)
        {
            if (items.Count > 0) { items.Add(new Item(Para, EditMark.Paragraph, true, false)); aiTokens.Add(Para); }
            foreach (var it in MergeChunk(chunk))
            {
                items.Add(it);
                if (it.InAi) aiTokens.Add(it.Text);
            }
        }

        // The user's edits in the Formatted tab, lined up with the AI's text.
        var formatted = Tokens(s.Formatted);
        var withFormatted = aiTokens.Count == 0 && formatted.Length == 0 ? items : MergeFormatted(items, aiTokens, formatted);

        // The transcript not formatted yet: the user's edits of what was heard.
        var heardRest = Tokens(s.Heard[Math.Min(s.HeardFormattedThrough, s.Heard.Length)..]);
        var transcriptRest = Tokens(s.Transcript[Math.Min(s.FormattedThrough, s.Transcript.Length)..]);
        var rest = new List<Item>();
        foreach (var t in LongDiff.Compute(heardRest, transcriptRest))
            rest.Add(t.Kind switch
            {
                DiffKind.Same => new Item(t.Word, t.Word == Para ? EditMark.Paragraph : EditMark.Plain, false, false),
                DiffKind.Removed => new Item(t.Word, EditMark.UserRemoved, false, false),
                _ => new Item(t.Word, t.Word == Para ? EditMark.Paragraph : EditMark.UserNote, false, true),
            });
        Classify(rest);
        if (withFormatted.Count > 0 && rest.Count > 0) withFormatted.Add(new Item(Para, EditMark.Paragraph, false, false));
        withFormatted.AddRange(rest);

        return withFormatted.Where(i => !(i.Text == Para && i.Mark is EditMark.UserRemoved or EditMark.AiRemoved))
            .Select(i => new EditPiece(i.Text, i.Mark)).ToList();
    }

    /// <summary>
    /// One formatting step: heard → sent (the user's edits) and sent → AI (the AI's edits), merged along the words that
    /// were sent. Both diffs pass through every sent word in order; between them sit the heard words the user removed
    /// and the words the AI added.
    /// </summary>
    static List<Item> MergeChunk(NoteChunk c)
    {
        var heard = Tokens(c.Heard);
        var sent = Tokens(c.Sent);
        var ai = Tokens(c.Ai);
        var user = LongDiff.Compute(heard, sent);
        var aiDiff = LongDiff.Compute(sent, ai);
        var output = new List<Item>();
        int i = 0, j = 0;
        while (i < user.Count || j < aiDiff.Count)
        {
            while (i < user.Count && user[i].Kind == DiffKind.Removed)
                output.Add(new Item(user[i++].Word, EditMark.UserRemoved, false, false));
            while (j < aiDiff.Count && aiDiff[j].Kind == DiffKind.Added)
            {
                var w = aiDiff[j++].Word;
                output.Add(new Item(w, w == Para ? EditMark.AiParagraph : EditMark.AiAdded, true, false));
            }
            if (i >= user.Count || j >= aiDiff.Count)
            {
                // Out of step (shouldn't happen): keep what is left of the AI's text, so nothing goes missing.
                for (; j < aiDiff.Count; j++)
                    if (aiDiff[j].Kind != DiffKind.Removed) output.Add(new Item(aiDiff[j].Word, EditMark.Plain, true, false));
                break;
            }
            var typedByUser = user[i].Kind == DiffKind.Added;
            var removedByAi = aiDiff[j].Kind == DiffKind.Removed;
            var word = aiDiff[j].Word; // the AI's spelling where it kept the word
            output.Add(removedByAi
                ? new Item(word, EditMark.AiRemoved, false, typedByUser)
                : new Item(word, word == Para ? EditMark.Paragraph : typedByUser ? EditMark.UserNote : EditMark.Plain, true, typedByUser));
            i++; j++;
        }
        Classify(output);
        return output;
    }

    /// <summary>The user's edits in the Formatted tab: the AI's words they removed, and what they typed.</summary>
    static List<Item> MergeFormatted(List<Item> items, List<string> aiTokens, string[] formatted)
    {
        var diff = LongDiff.Compute(aiTokens, formatted);
        var output = new List<Item>(items.Count + 16);
        var j = 0;
        void Typed()
        {
            while (j < diff.Count && diff[j].Kind == DiffKind.Added)
            {
                var w = diff[j++].Word;
                output.Add(new Item(w, w == Para ? EditMark.Paragraph : EditMark.UserNote, false, true));
            }
        }
        foreach (var it in items)
        {
            if (!it.InAi) { output.Add(it); continue; }
            Typed();
            if (j < diff.Count && diff[j].Kind == DiffKind.Removed) { output.Add(it with { Mark = EditMark.UserRemoved, InAi = false }); j++; }
            else { output.Add(it); if (j < diff.Count) j++; }
        }
        Typed();
        Classify(output);
        return output;
    }

    /// <summary>A run of typed words right next to words the user removed replaced them: "changed", not a note.</summary>
    static void Classify(List<Item> items)
    {
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i].Mark != EditMark.UserNote) continue;
            var start = i;
            while (i + 1 < items.Count && items[i + 1].Mark == EditMark.UserNote) i++;
            var before = start > 0 && items[start - 1].Mark == EditMark.UserRemoved;
            var after = i + 1 < items.Count && items[i + 1].Mark == EditMark.UserRemoved;
            if (!before && !after) continue;
            for (var k = start; k <= i; k++) items[k] = items[k] with { Mark = EditMark.UserChanged };
        }
    }
}
