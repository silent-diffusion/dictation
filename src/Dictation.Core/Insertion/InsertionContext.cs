using System.Text.RegularExpressions;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Insertion;

/// <summary>
/// The text immediately around the caret in the target app, read through UI Automation when the app exposes it
/// (Word, browsers, Notepad and most standard edit controls do). Only a sentence or two on each side is kept.
/// It never leaves the machine, is never logged, and is not sent to the AI model.
/// </summary>
public sealed record InsertionContext(string Before, string After)
{
    const int ReadChars = 240;

    /// <summary>Best effort: null when the focused control has no text pattern or the app is slow to answer.</summary>
    public static async Task<InsertionContext?> CaptureAsync(TimeSpan timeout)
    {
        // UI Automation calls into the other process and can block, so keep them off the UI thread and bounded.
        var read = Task.Run(Read);
        var done = await Task.WhenAny(read, Task.Delay(timeout));
        return done == read ? read.Result : null;
    }

    static InsertionContext? Read()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused == null || !focused.TryGetCurrentPattern(TextPattern.Pattern, out var p)) return null;
            var selection = ((TextPattern)p).GetSelection();
            if (selection.Length == 0) return null;
            var caret = selection[0];

            var before = caret.Clone();
            before.MoveEndpointByRange(TextPatternRangeEndpoint.End, caret, TextPatternRangeEndpoint.Start);
            before.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -ReadChars);

            var after = caret.Clone();
            after.MoveEndpointByRange(TextPatternRangeEndpoint.Start, caret, TextPatternRangeEndpoint.End);
            after.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, ReadChars);

            return Trim(before.GetText(ReadChars), after.GetText(ReadChars));
        }
        catch (Exception e)
        {
            Log.Info("No text context from the target app: " + e.GetType().Name);
            return null;
        }
    }

    /// <summary>Keep at most the last two sentences before the caret and the first sentence after it.</summary>
    public static InsertionContext Trim(string before, string after)
    {
        var starts = Regex.Matches(before, @"(?<=[.!?])\s+|\n").Cast<Match>().Select(m => m.Index + m.Length).ToList();
        if (starts.Count >= 2) before = before[starts[^2]..];
        var end = Regex.Match(after, @"[.!?](\s|$)|\n");
        if (end.Success) after = after[..(end.Index + 1)];
        return new InsertionContext(before, after);
    }
}

/// <summary>Adjusts dictated text so it fits where it is inserted: capitalization, a trailing period and spacing.</summary>
public static class ContextFit
{
    /// <summary>Up to this many words count as a "short phrase" that should not get its own period mid-sentence.</summary>
    const int ShortPhraseWords = 6;

    public static string Apply(string text, InsertionContext? context)
    {
        text = text.Trim();
        if (context == null || text.Length == 0) return text;
        var before = context.Before;
        var after = context.After;

        var lastBefore = before.TrimEnd(' ', '\t').LastOrDefault();
        var atSentenceStart = lastBefore is '\0' or '.' or '!' or '?' or '\n' or '\r';
        var nextChar = after.TrimStart(' ', '\t').FirstOrDefault();

        // Capitalization of the first word
        if (atSentenceStart) text = char.ToUpper(text[0]) + text[1..];
        else if (ShouldLowercase(text, before)) text = char.ToLower(text[0]) + text[1..];

        // Trailing period: drop it when the sentence clearly continues, or when a short phrase lands mid-sentence
        // (unless what follows is the start of a new sentence).
        if (text.EndsWith('.') && !text.EndsWith("..."))
        {
            var continues = char.IsLower(nextChar) || char.IsDigit(nextChar) || nextChar is ',' or ';' or ':' or '.' or ')' or '!' or '?';
            var shortFragment = !atSentenceStart && IsSingleSentence(text) && WordCount(text) <= ShortPhraseWords && !char.IsUpper(nextChar);
            if (continues || shortFragment) text = text[..^1];
        }

        // Spacing, so the new words don't run into the old ones
        var prev = before.LastOrDefault();
        if (prev != '\0' && !char.IsWhiteSpace(prev) && prev is not ('(' or '[' or '{' or '"' or '“' or '\'' or '/' or '-')
            && char.IsLetterOrDigit(text[0]))
            text = " " + text;
        var next = after.FirstOrDefault();
        if (next != '\0' && char.IsLetterOrDigit(next)) text += " ";
        return text;
    }

    /// <summary>Lowercase the first word mid-sentence, unless it looks like a name, an acronym or "I".</summary>
    static bool ShouldLowercase(string text, string before)
    {
        var first = new string(text.TakeWhile(c => char.IsLetter(c) || c == '\'').ToArray());
        if (first.Length == 0 || !char.IsUpper(first[0])) return false;
        if (first == "I" || first.StartsWith("I'")) return false;
        if (first.Skip(1).Any(char.IsUpper)) return false; // NASA, iPhone-style, McDonald
        // A word that is capitalized elsewhere mid-sentence (in the dictation or around it) is probably a name.
        var elsewhere = before + " " + text[first.Length..];
        return !Regex.IsMatch(elsewhere, @"(?<![.!?]\s*|^)\b" + Regex.Escape(first) + @"\b");
    }

    static bool IsSingleSentence(string text) => !Regex.IsMatch(text.TrimEnd('.', '!', '?'), @"[.!?]\s");
    static int WordCount(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}
