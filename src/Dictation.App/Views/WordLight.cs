using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// Lights up the word being played back in a text shown as runs (a TextBlock, or a rendered Markdown view): the accent
/// colour on the accent wash, nothing that changes the layout. The word's run is split off the text around it (same
/// formatting), so only its colour changes. While playing it keeps the word in view, scrolling when it nears an edge,
/// except for <see cref="ManualPause"/> after the reader scrolled themselves.
/// </summary>
sealed class WordLight
{
    public static readonly TimeSpan ManualPause = TimeSpan.FromSeconds(5);

    readonly FrameworkElement _host;
    readonly RichTextBox? _viewer;
    /// <summary>The runs, by where they start in the text the words were matched in, in order.</summary>
    readonly List<(int Offset, Run Run)> _runs = new();
    string _text = "";
    SpokenWords _words = SpokenWords.None;
    int _index = -1;
    Run? _lit;
    object? _foreground, _background; // the lit run's own colours, put back when it goes out
    bool _litForeground, _litBackground;
    DateTime _manualUntil = DateTime.MinValue;

    /// <param name="host">The TextBlock or RichTextBox the runs are in.</param>
    /// <param name="scroller">What the reader scrolls: the RichTextBox itself, or the ScrollViewer around a TextBlock
    /// (null: the text is never scrolled to).</param>
    public WordLight(FrameworkElement host, UIElement? scroller)
    {
        _host = host;
        _viewer = host as RichTextBox;
        if (scroller == null) return;
        // The reader's own scrolling (wheel, scroll bar, keys, touch): the text stays where they put it for a while.
        scroller.PreviewMouseWheel += (_, _) => Manual();
        scroller.PreviewTouchDown += (_, _) => Manual();
        scroller.PreviewMouseLeftButtonDown += (_, e) => { if (InScrollBar(e.OriginalSource as DependencyObject)) Manual(); };
        scroller.PreviewKeyDown += (_, e) =>
        {
            if (e.Key is Key.PageUp or Key.PageDown or Key.Home or Key.End or Key.Up or Key.Down) Manual();
        };
    }

    void Manual() => _manualUntil = DateTime.Now + ManualPause;

    /// <summary>What the runs were taken from (a document, an entry), as given to <see cref="Attach"/>: when it changes,
    /// they must be taken again.</summary>
    public object? Source { get; private set; }

    /// <summary>The text shown, its runs (where each starts in <paramref name="text"/>) and its words' timings; what was
    /// lit before goes (its runs may be gone).</summary>
    public void Attach(object? source, string text, IEnumerable<(int Offset, Run Run)> runs, SpokenWords words)
    {
        Clear();
        Source = source;
        _text = text;
        _runs.Clear();
        _runs.AddRange(runs);
        _words = words;
    }

    /// <summary>Nothing to light any more (another text is shown).</summary>
    public void Detach() => Attach(null, "", Array.Empty<(int, Run)>(), SpokenWords.None);

    /// <summary>Light the word said at <paramref name="seconds"/> (none in a pause), and, with <paramref name="follow"/>,
    /// bring it into view unless the reader scrolled a moment ago.</summary>
    public void Show(double seconds, bool follow)
    {
        var index = _words.At(seconds);
        if (index == _index) return;
        Clear();
        if (index < 0) return;
        _index = index;
        var word = _words.Words[index];
        if (Split(word.Offset, word.Length) is not { } run) return;
        _foreground = run.ReadLocalValue(TextElement.ForegroundProperty);
        _background = run.ReadLocalValue(TextElement.BackgroundProperty);
        // Only a colour of its own that is a plain value (or none) can be put back exactly; one set any other way (a
        // theme resource) stays. A run with a background of its own (code) keeps it.
        _litForeground = _foreground == DependencyProperty.UnsetValue || _foreground is System.Windows.Media.Brush;
        _litBackground = _background == DependencyProperty.UnsetValue;
        if (_litForeground) run.SetResourceReference(TextElement.ForegroundProperty, "Ob.Accent");
        if (_litBackground) run.SetResourceReference(TextElement.BackgroundProperty, "Ob.AccentWash");
        _lit = run;
        if (follow && DateTime.Now >= _manualUntil) Follow(run);
    }

    /// <summary>Nothing lit (paused, stopped, the end, another tab).</summary>
    public void Clear()
    {
        _index = -1;
        if (_lit is not { } run) return;
        if (_litForeground) Restore(run, TextElement.ForegroundProperty, _foreground);
        if (_litBackground) Restore(run, TextElement.BackgroundProperty, _background);
        _lit = null;
    }

    static void Restore(Run run, DependencyProperty property, object? saved)
    {
        if (saved == DependencyProperty.UnsetValue) run.ClearValue(property);
        else run.SetValue(property, saved);
    }

    /// <summary>The run holding exactly the word at [offset, offset + length) of the text: the run it is in, split so the
    /// word has one of its own. Null when the word isn't inside a single run as written there (it straddles bold and
    /// plain, the run shows other text, or its formatting can't be copied).</summary>
    Run? Split(int offset, int length)
    {
        int lo = 0, hi = _runs.Count - 1, at = -1;
        while (lo <= hi)
        {
            var mid = (lo + hi) / 2;
            if (_runs[mid].Offset <= offset) { at = mid; lo = mid + 1; }
            else hi = mid - 1;
        }
        if (at < 0 || offset + length > _text.Length) return null;
        var (start, run) = _runs[at];
        var text = run.Text;
        var from = offset - start;
        if (from + length > text.Length || string.CompareOrdinal(text, from, _text, offset, length) != 0) return null;
        if (from == 0 && length == text.Length) return run;
        if (run.SiblingInlines is not { } siblings || Copy(run, text.Substring(from, length), from) is not { } word) return null;
        var after = text[(from + length)..];
        var pieces = new List<(int, Run)>();
        if (from > 0)
        {
            // The run keeps what comes before the word; the word, then what follows it, go after it.
            Run? rest = null;
            if (after.Length > 0 && (rest = Copy(run, after, from + length)) == null) return null;
            run.Text = text[..from];
            siblings.InsertAfter(run, word);
            if (rest != null) siblings.InsertAfter(word, rest);
            pieces.Add((start, run));
            pieces.Add((offset, word));
            if (rest != null) pieces.Add((offset + length, rest));
        }
        else
        {
            // The word begins the run: it goes before it, and the run keeps the rest.
            siblings.InsertBefore(run, word);
            run.Text = after;
            if (run.Tag is int tag) run.Tag = tag + length;
            pieces.Add((offset, word));
            pieces.Add((offset + length, run));
        }
        _runs.RemoveAt(at);
        _runs.InsertRange(at, pieces);
        return word;
    }

    /// <summary>A run with <paramref name="text"/> and the formatting of <paramref name="run"/>; a Markdown run's offset
    /// (its Tag) moved by <paramref name="shift"/>. Null when its formatting is set some way that can't be copied.</summary>
    static Run? Copy(Run run, string text, int shift)
    {
        var copy = new Run(text);
        var values = run.GetLocalValueEnumerator();
        while (values.MoveNext())
        {
            var entry = values.Current;
            if (entry.Property == Run.TextProperty || entry.Property.ReadOnly) continue;
            if (entry.Value is Expression) return null;
            copy.SetValue(entry.Property, entry.Value);
        }
        if (run.Tag is int tag) copy.Tag = tag + shift;
        return copy;
    }

    /// <summary>Keep the lit word in view: when it nears the top or bottom, it is brought a third of the way down.</summary>
    void Follow(Run run)
    {
        Rect rect;
        try { rect = run.ContentStart.GetCharacterRect(LogicalDirection.Forward); }
        catch (InvalidOperationException) { return; } // not laid out
        if (rect.IsEmpty) return;
        if (_viewer != null)
        {
            // In a RichTextBox the rectangle is where the word is on screen, the scrolling taken into account.
            var margin = Math.Min(rect.Height * 2, _viewer.ViewportHeight / 4);
            if (rect.Top >= margin && rect.Bottom <= _viewer.ViewportHeight - margin) return;
            _viewer.ScrollToVerticalOffset(Math.Max(0, _viewer.VerticalOffset + rect.Top - _viewer.ViewportHeight / 3));
            return;
        }
        // In a TextBlock it is where the word is in the block; the ScrollViewer around it scrolls as little as it can,
        // so a line above and below come along.
        rect.Inflate(0, rect.Height * 1.5);
        _host.BringIntoView(rect);
    }

    static bool InScrollBar(DependencyObject? d)
    {
        for (; d is System.Windows.Media.Visual; d = System.Windows.Media.VisualTreeHelper.GetParent(d))
            if (d is ScrollBar) return true;
        return false;
    }
}
