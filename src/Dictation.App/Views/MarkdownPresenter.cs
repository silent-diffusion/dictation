using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// Shows a text box's text rendered as Markdown (<see cref="NotesMarkdown"/>), for reading, and turns back into the
/// plain text box to edit: a click puts the cursor there, typing starts at the end, and leaving the box shows the
/// rendered text again. The box stays the source of truth (it is what the session binds to); the rendering follows it,
/// a moment after each change, keeping the reader at the end while new text arrives.
/// </summary>
sealed class MarkdownPresenter
{
    readonly TextBox _box;
    readonly double _fontSize;
    readonly DispatcherTimer _render = new() { Interval = TimeSpan.FromMilliseconds(300) };
    bool _editing, _dirty = true, _shown = true;

    /// <summary>The rendered view (read only); its runs carry where their text starts in the box's text.</summary>
    public RichTextBox Viewer { get; }

    /// <param name="box">A text box whose parent is a panel; the view is put beside it, in the same place.</param>
    public MarkdownPresenter(TextBox box, double fontSize)
    {
        _box = box;
        _fontSize = fontSize;
        Viewer = new RichTextBox
        {
            IsReadOnly = true, IsDocumentEnabled = false, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = box.Padding, FontSize = fontSize,
            Cursor = Cursors.IBeam, IsReadOnlyCaretVisible = false,
        };
        AutomationProperties.SetName(Viewer, AutomationProperties.GetName(box) + ", formatted for reading; click to edit");
        if (box.Parent is Panel panel)
        {
            Grid.SetRow(Viewer, Grid.GetRow(box));
            Grid.SetColumn(Viewer, Grid.GetColumn(box));
            panel.Children.Insert(panel.Children.IndexOf(box) + 1, Viewer);
        }
        box.TextChanged += (_, _) => { _dirty = true; if (!_render.IsEnabled) _render.Start(); };
        _render.Tick += (_, _) => { _render.Stop(); if (!_editing) Render(); };
        box.LostKeyboardFocus += (_, e) => { if (!InMenu(e.NewFocus as DependencyObject)) ShowView(); };
        Viewer.PreviewMouseLeftButtonUp += (_, e) =>
        {
            // A drag selects text to copy; a plain click goes into the text there.
            if (!Viewer.Selection.IsEmpty) return;
            Edit(OffsetAt(e.GetPosition(Viewer)));
            e.Handled = true;
        };
        Viewer.PreviewTextInput += (_, e) =>
        {
            // Typing while reading: it goes on at the end of the text.
            Edit(_box.Text.Length);
            _box.SelectedText = e.Text;
            _box.CaretIndex += e.Text.Length;
            e.Handled = true;
        };
        Viewer.Loaded += (_, _) => { if (_dirty) Render(); };
        Apply();
    }

    /// <summary>Whether the pair is on screen at all (the tab is showing); which of the two depends on editing.</summary>
    public bool Shown
    {
        get => _shown;
        set { _shown = value; Apply(); }
    }

    public bool Editing => _editing;

    void Apply()
    {
        _box.Visibility = _shown && _editing ? Visibility.Visible : Visibility.Collapsed;
        Viewer.Visibility = _shown && !_editing ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>To the plain text box, with the cursor at <paramref name="offset"/> and that line in view.</summary>
    public void Edit(int offset)
    {
        _editing = true;
        Apply();
        _box.CaretIndex = Math.Clamp(offset, 0, _box.Text.Length);
        // The box was hidden a moment ago: it can take the focus, and scroll, once it has been laid out.
        _box.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            _box.Focus();
            var line = _box.GetLineIndexFromCharacterIndex(_box.CaretIndex);
            if (line >= 0) _box.ScrollToLine(line);
        });
    }

    /// <summary>Back to the rendered text, brought up to date.</summary>
    public void ShowView()
    {
        if (!_editing) return;
        _editing = false;
        Render();
        Apply();
    }

    static bool InMenu(DependencyObject? d)
    {
        for (; d != null; d = (d is Visual ? VisualTreeHelper.GetParent(d) : null) ?? LogicalTreeHelper.GetParent(d))
            if (d is ContextMenu or MenuItem) return true;
        return false;
    }

    /// <summary>Where in the box's text the rendered text at <paramref name="point"/> (in the view) came from.</summary>
    public int OffsetAt(Point point)
    {
        var pointer = Viewer.GetPositionFromPoint(point, true);
        if (pointer == null) return _box.Text.Length;
        if (pointer.Parent is Run { Tag: int start } run)
            return Math.Clamp(start + run.ContentStart.GetOffsetToPosition(pointer), 0, _box.Text.Length);
        if (pointer.GetAdjacentElement(LogicalDirection.Forward) is Run { Tag: int next }) return Math.Clamp(next, 0, _box.Text.Length);
        if (pointer.GetAdjacentElement(LogicalDirection.Backward) is Run { Tag: int prev } before)
            return Math.Clamp(prev + before.Text.Length, 0, _box.Text.Length);
        return _box.Text.Length;
    }

    void Render()
    {
        _dirty = false;
        var atEnd = Viewer.ExtentHeight <= Viewer.ViewportHeight + 4 || Viewer.VerticalOffset + Viewer.ViewportHeight >= Viewer.ExtentHeight - 4;
        var offset = Viewer.VerticalOffset;
        Viewer.Document = MarkdownRender.Document(_box.Text, _fontSize);
        if (atEnd) Viewer.ScrollToEnd();
        else Viewer.ScrollToVerticalOffset(offset);
    }
}

/// <summary>Markdown blocks (<see cref="NotesMarkdown"/>) as a document in the app's own look, light or dark.</summary>
static class MarkdownRender
{
    public static FlowDocument Document(string text, double size)
    {
        var doc = new FlowDocument { PagePadding = new Thickness(0), FontSize = size, LineHeight = size * 1.55 };
        doc.SetResourceReference(FlowDocument.ForegroundProperty, "Ob.Text");
        doc.SetResourceReference(FlowDocument.FontFamilyProperty, "Ob.Ui");
        var mono = (FontFamily)Application.Current.FindResource("Ob.Mono");
        foreach (var b in NotesMarkdown.Parse(text))
        {
            var p = new Paragraph { Margin = new Thickness(0, 0, 0, size * 0.75) };
            switch (b.Kind)
            {
                case MdKind.Heading:
                    var scale = b.Level switch { 1 => 1.55, 2 => 1.32, 3 => 1.16, _ => 1.05 };
                    p.FontSize = size * scale;
                    p.LineHeight = size * scale * 1.3;
                    p.FontWeight = FontWeights.Bold;
                    p.Margin = new Thickness(0, size * 0.5, 0, size * 0.4);
                    break;
                case MdKind.Bullet:
                case MdKind.Numbered:
                    var indent = 20 + b.Level * 20;
                    p.Margin = new Thickness(indent, 0, 0, size * 0.3);
                    p.TextIndent = -16;
                    var mark = new Run(b.Kind == MdKind.Bullet ? "•  " : b.Number + ".  ");
                    mark.SetResourceReference(TextElement.ForegroundProperty, "Ob.Muted");
                    p.Inlines.Add(mark);
                    break;
                case MdKind.Quote:
                    p.BorderThickness = new Thickness(2, 0, 0, 0);
                    p.Padding = new Thickness(12, 2, 0, 2);
                    p.SetResourceReference(Block.BorderBrushProperty, "Ob.Border");
                    p.SetResourceReference(TextElement.ForegroundProperty, "Ob.Muted");
                    break;
                case MdKind.Code:
                    p.FontFamily = mono;
                    p.FontSize = size * 0.92;
                    p.Padding = new Thickness(10, 6, 10, 6);
                    p.SetResourceReference(TextElement.BackgroundProperty, "Ob.Subtle");
                    break;
                case MdKind.Rule:
                    p.FontSize = 2;
                    p.LineHeight = 2;
                    p.BorderThickness = new Thickness(0, 0, 0, 1);
                    p.Margin = new Thickness(0, size * 0.3, 0, size * 0.9);
                    p.SetResourceReference(Block.BorderBrushProperty, "Ob.Divider");
                    p.Inlines.Add(new Run(" ") { Tag = b.Offset });
                    break;
                case MdKind.Marker:
                    p.FontFamily = mono;
                    p.FontWeight = FontWeights.Bold;
                    p.FontSize = size * 0.9;
                    p.SetResourceReference(TextElement.ForegroundProperty, "Ob.Accent");
                    break;
            }
            foreach (var span in b.Spans)
            {
                if (span.Break) { p.Inlines.Add(new LineBreak()); continue; }
                var run = new Run(span.Text) { Tag = span.Offset };
                if (span.Bold) run.FontWeight = FontWeights.Bold;
                if (span.Italic) run.FontStyle = FontStyles.Italic;
                if (span.Code && b.Kind != MdKind.Code)
                {
                    run.FontFamily = mono;
                    run.FontSize = size * 0.92;
                    run.SetResourceReference(TextElement.BackgroundProperty, "Ob.Subtle");
                }
                p.Inlines.Add(run);
            }
            doc.Blocks.Add(p);
        }
        return doc;
    }
}
