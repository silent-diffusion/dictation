using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>Shows a word diff in a TextBlock: removed words struck through, added words highlighted.</summary>
public static class DiffText
{
    /// <param name="maxWords">Only the last this-many words are shown; earlier ones collapse into "…".</param>
    public static void Render(TextBlock target, IReadOnlyList<DiffToken> diff, Brush removed, Brush added, int maxWords = int.MaxValue)
    {
        target.Inlines.Clear();
        var start = Math.Max(0, diff.Count - maxWords);
        if (start > 0) target.Inlines.Add(new Run("… "));
        for (var i = start; i < diff.Count; i++)
        {
            var t = diff[i];
            var run = new Run(t.Word);
            if (t.Kind == DiffKind.Removed)
            {
                run.Foreground = removed;
                run.TextDecorations = TextDecorations.Strikethrough;
            }
            else if (t.Kind == DiffKind.Added) run.Foreground = added;
            target.Inlines.Add(run);
            if (i < diff.Count - 1) target.Inlines.Add(new Run(" ")); // separate, so the strike doesn't run into the gap
        }
    }
}
