using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Threading;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// Shows a text box's text rendered as Markdown (<see cref="NotesMarkdown"/>), and edits it a line at a time, in place:
/// a click opens the line clicked as plain text (its Markdown syntax showing), and every other line stays rendered.
/// When the cursor leaves the line (another click, the arrow keys, Enter, or leaving the box) that line is rendered
/// again. Typing while reading goes on at the end. The box itself stays hidden and stays the source of truth (it is what
/// the session binds to): the line being edited writes into it, and the rendering follows it, a moment after each
/// change made elsewhere, keeping the reader at the end while new text arrives.
/// </summary>
sealed class MarkdownPresenter
{
    readonly TextBox _box;
    readonly double _fontSize;
    readonly DispatcherTimer _render = new() { Interval = TimeSpan.FromMilliseconds(300) };
    bool _editing, _dirty = true, _shown = true, _selfEdit;
    /// <summary>The line being edited (its index in the box's text), and the plain-text box showing it.</summary>
    int _line;
    TextBox? _editor;
    /// <summary>The text as it was rendered: the runs' offsets point into it.</summary>
    string _rendered = "";

    static readonly Regex ListItem = new(@"^(\s*)(?:([-*+•])|(\d{1,3})([.)]))\s+", RegexOptions.Compiled);
    static ControlTemplate? _lineTemplate;

    /// <summary>The rendered view; its runs carry where their text starts in the box's text.</summary>
    public RichTextBox Viewer { get; }

    /// <param name="box">A text box whose parent is a panel; the view is put beside it, in the same place.</param>
    public MarkdownPresenter(TextBox box, double fontSize)
    {
        _box = box;
        _fontSize = fontSize;
        // A box that is hidden (another tab is showing) starts with its view hidden too: views share the same place.
        _shown = box.Visibility == Visibility.Visible;
        Viewer = new RichTextBox
        {
            // Document enabled: the line being edited is a text box inside the document, and must take the keyboard.
            IsReadOnly = true, IsDocumentEnabled = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = box.Padding, FontSize = fontSize,
            Cursor = Cursors.IBeam, IsReadOnlyCaretVisible = false,
        };
        AutomationProperties.SetName(Viewer, AutomationProperties.GetName(box) + ", formatted for reading; click a line to edit it");
        if (box.Parent is Panel panel)
        {
            Grid.SetRow(Viewer, Grid.GetRow(box));
            Grid.SetColumn(Viewer, Grid.GetColumn(box));
            panel.Children.Insert(panel.Children.IndexOf(box) + 1, Viewer);
        }
        box.TextChanged += (_, _) =>
        {
            if (_selfEdit) return; // the line being edited wrote it: the rest of the rendering is still right
            _dirty = true;
            if (!_render.IsEnabled) _render.Start();
        };
        _render.Tick += (_, _) => { _render.Stop(); if (_dirty) Render(); };
        Viewer.PreviewMouseLeftButtonDown += (_, e) =>
        {
            // While a line is open, a click on another line moves there at once (before the open line is rendered
            // again and the text under the mouse shifts).
            if (!_editing || _editor?.IsMouseOver == true || InScrollBar(e.OriginalSource as DependencyObject)) return;
            var (line, col) = Locate(_rendered, RenderedOffsetAt(e.GetPosition(Viewer)));
            MoveTo(line, col);
            e.Handled = true;
        };
        Viewer.PreviewMouseLeftButtonUp += (_, e) =>
        {
            // A drag selects text to copy; a plain click opens the line there.
            if (_editing || !Viewer.Selection.IsEmpty || InScrollBar(e.OriginalSource as DependencyObject)) return;
            Edit(OffsetAt(e.GetPosition(Viewer)));
            e.Handled = true;
        };
        Viewer.PreviewTextInput += (_, e) =>
        {
            if (_editing) return; // it is the open line's
            // Typing while reading: it goes on at the end of the text.
            WriteBox(_box.Text.Length, 0, e.Text);
            Edit(_box.Text.Length);
            e.Handled = true;
        };
        Viewer.Loaded += (_, _) => { if (_dirty) Render(); };
        Apply();
    }

    /// <summary>Whether the view is on screen at all (its tab is showing).</summary>
    public bool Shown
    {
        get => _shown;
        set
        {
            _shown = value;
            if (!value) ShowView();
            Apply();
        }
    }

    public bool Editing => _editing;

    void Apply()
    {
        _box.Visibility = Visibility.Collapsed;
        Viewer.Visibility = _shown ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Opens the line holding <paramref name="offset"/> (in the box's text) for editing, the cursor there.</summary>
    public void Edit(int offset)
    {
        var (line, col) = Locate(_box.Text, offset);
        MoveTo(line, col);
    }

    /// <summary>Back to the whole text rendered, brought up to date.</summary>
    public void ShowView()
    {
        if (!_editing) return;
        _editing = false;
        _editor = null;
        Render();
    }

    /// <summary>Opens line <paramref name="line"/> with the cursor at <paramref name="col"/>; the line open before is
    /// rendered again.</summary>
    void MoveTo(int line, int col)
    {
        var text = _box.Text;
        line = Math.Clamp(line, 0, LineCount(text) - 1);
        var (start, length) = LineRange(text, line);
        _editing = true;
        _line = line;
        var editor = NewEditor(text.Substring(start, length));
        _editor = editor;
        Render();
        Focus(editor, Math.Clamp(col, 0, length), 0);
        _box.CaretIndex = start + Math.Clamp(col, 0, length); // the Play button starts from here
    }

    /// <summary>The open line takes the keyboard, once it has been laid out (it was just put into the document).</summary>
    void Focus(TextBox editor, int caret, int selected)
    {
        Viewer.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            if (!ReferenceEquals(editor, _editor)) return;
            editor.Focus();
            editor.Select(Math.Min(caret, editor.Text.Length), Math.Clamp(selected, 0, editor.Text.Length - Math.Min(caret, editor.Text.Length)));
            editor.BringIntoView();
        });
    }

    TextBox NewEditor(string text)
    {
        _lineTemplate ??= (ControlTemplate)XamlReader.Parse(
            "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' " +
            "xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='TextBox'>" +
            "<Border Background='{TemplateBinding Background}' Padding='{TemplateBinding Padding}' CornerRadius='3'>" +
            "<ScrollViewer x:Name='PART_ContentHost' Focusable='False' HorizontalScrollBarVisibility='Hidden' VerticalScrollBarVisibility='Hidden'/>" +
            "</Border></ControlTemplate>");
        var ed = new TextBox
        {
            Text = text, Template = _lineTemplate, TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, AcceptsTab = false,
            BorderThickness = new Thickness(0), Padding = new Thickness(4, 1, 4, 1), Margin = new Thickness(-4, 0, -4, 0),
            MinHeight = 0, FocusVisualStyle = null, HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        ed.SetResourceReference(Control.BackgroundProperty, "Ob.Subtle");
        ed.SetResourceReference(Control.ForegroundProperty, "Ob.Text");
        ed.SetResourceReference(TextBoxBase.CaretBrushProperty, "Ob.Text");
        ed.SetResourceReference(Control.FontFamilyProperty, "Ob.Ui");
        AutomationProperties.SetName(ed, AutomationProperties.GetName(_box) + ", the line being edited");
        FitFont(ed);
        ed.TextChanged += (_, _) =>
        {
            if (!ReferenceEquals(ed, _editor)) return;
            var (start, length) = LineRange(_box.Text, _line);
            WriteBox(start, length, ed.Text);
            _box.CaretIndex = start + ed.CaretIndex;
            FitFont(ed);
        };
        ed.SelectionChanged += (_, _) =>
        {
            if (ReferenceEquals(ed, _editor)) _box.CaretIndex = LineRange(_box.Text, _line).Start + ed.CaretIndex;
        };
        ed.PreviewKeyDown += (_, e) => OnKey(ed, e);
        ed.LostKeyboardFocus += (_, _) =>
        {
            // Checked a moment later: moving to another line, or the text being rendered again, takes the focus away
            // only for an instant. Leaving for a menu, or for another window, keeps the line open.
            Viewer.Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
            {
                if (!ReferenceEquals(ed, _editor) || ed.IsKeyboardFocusWithin) return;
                if (InMenu(Keyboard.FocusedElement as DependencyObject)) return;
                if (Window.GetWindow(Viewer) is { IsActive: false }) return;
                ShowView();
            });
        };
        DataObject.AddPastingHandler(ed, (_, e) =>
        {
            // More than one line pasted: it goes into the text as it is, and the line it ends on is opened.
            if (e.DataObject.GetData(DataFormats.UnicodeText) is not string pasted || !pasted.Contains('\n')) return;
            e.CancelCommand();
            var start = LineRange(_box.Text, _line).Start + ed.SelectionStart;
            WriteBox(start, ed.SelectionLength, pasted);
            Edit(start + pasted.Length);
        });
        return ed;
    }

    /// <summary>A heading being edited keeps its size, so the text doesn't jump as the cursor goes in and out.</summary>
    void FitFont(TextBox ed)
    {
        var level = NotesMarkdown.Parse(ed.Text) is [{ Kind: MdKind.Heading } h] ? h.Level : 0;
        ed.FontSize = _fontSize * MarkdownRender.HeadingScale(level);
        ed.FontWeight = level > 0 ? FontWeights.Bold : FontWeights.Normal;
    }

    /// <summary>The keys that move between lines, split one, or join two.</summary>
    void OnKey(TextBox ed, KeyEventArgs e)
    {
        if (!ReferenceEquals(ed, _editor)) return;
        var text = _box.Text;
        var (start, length) = LineRange(text, _line);
        var last = LineCount(text) - 1;
        var caret = ed.CaretIndex;
        var none = ed.SelectionLength == 0;
        var mods = Keyboard.Modifiers & ~ModifierKeys.Shift;
        switch (e.Key)
        {
            case System.Windows.Input.Key.Enter when mods == ModifierKeys.None:
                Split(ed, start);
                break;
            case System.Windows.Input.Key.Escape:
                ShowView();
                Viewer.Focus();
                break;
            case System.Windows.Input.Key.Up when mods == ModifierKeys.None && Keyboard.Modifiers == ModifierKeys.None && _line > 0 && VisualLine(ed) <= 0:
                MoveTo(_line - 1, caret);
                break;
            case System.Windows.Input.Key.Down when mods == ModifierKeys.None && Keyboard.Modifiers == ModifierKeys.None && _line < last && VisualLine(ed) >= ed.LineCount - 1:
                MoveTo(_line + 1, caret);
                break;
            case System.Windows.Input.Key.Left when Keyboard.Modifiers == ModifierKeys.None && none && caret == 0 && _line > 0:
                MoveTo(_line - 1, int.MaxValue);
                break;
            case System.Windows.Input.Key.Right when Keyboard.Modifiers == ModifierKeys.None && none && caret == length && _line < last:
                MoveTo(_line + 1, 0);
                break;
            case System.Windows.Input.Key.Back when mods == ModifierKeys.None && none && caret == 0 && _line > 0:
            {
                // Joined to the line above, the cursor where they meet.
                var above = LineRange(text, _line - 1);
                WriteBox(above.Start + above.Length, start - (above.Start + above.Length), "");
                MoveTo(_line - 1, above.Length);
                break;
            }
            case System.Windows.Input.Key.Delete when mods == ModifierKeys.None && none && caret == length && _line < last:
            {
                var below = LineRange(text, _line + 1);
                WriteBox(start + length, below.Start - (start + length), "");
                MoveTo(_line, caret);
                break;
            }
            default:
                return;
        }
        e.Handled = true;
    }

    /// <summary>Enter: the line splits at the cursor and the cursor goes to the new line. A list goes on (the next
    /// bullet, the next number); Enter on an empty list item ends the list.</summary>
    void Split(TextBox ed, int start)
    {
        var at = ed.SelectionStart;
        var newline = _box.Text.Contains("\r\n") ? "\r\n" : "\n";
        var prefix = "";
        if (ListItem.Match(ed.Text) is { Success: true } m && at >= m.Length)
        {
            if (ed.Text.Trim() == m.Value.Trim())
            {
                // An empty item: it is cleared, and the list ends here.
                WriteBox(start, ed.Text.Length, "");
                MoveTo(_line, 0);
                return;
            }
            prefix = m.Groups[2].Success
                ? m.Groups[1].Value + m.Groups[2].Value + " "
                : m.Groups[1].Value + (int.Parse(m.Groups[3].Value) + 1) + m.Groups[4].Value + " ";
        }
        WriteBox(start + at, ed.SelectionLength, newline + prefix);
        MoveTo(_line + 1, prefix.Length);
    }

    static int VisualLine(TextBox ed)
    {
        var i = ed.GetLineIndexFromCharacterIndex(ed.CaretIndex);
        return i < 0 ? 0 : i;
    }

    /// <summary>A change to the box's text made here (it doesn't need the rest of the text rendered again).</summary>
    void WriteBox(int start, int length, string text)
    {
        _selfEdit = true;
        try
        {
            _box.Select(start, length);
            _box.SelectedText = text;
        }
        finally { _selfEdit = false; }
    }

    static bool InMenu(DependencyObject? d)
    {
        for (; d != null; d = (d is Visual ? VisualTreeHelper.GetParent(d) : null) ?? LogicalTreeHelper.GetParent(d))
            if (d is ContextMenu or MenuItem) return true;
        return false;
    }

    static bool InScrollBar(DependencyObject? d)
    {
        for (; d is Visual; d = VisualTreeHelper.GetParent(d))
            if (d is ScrollBar) return true;
        return false;
    }

    /// <summary>Where in the box's text the rendered text at <paramref name="point"/> (in the view) came from.</summary>
    public int OffsetAt(Point point)
    {
        if (_editing && _editor is { IsMouseOver: true } ed)
        {
            // On the open line: the character there.
            var at = ed.GetCharacterIndexFromPoint(Viewer.TranslatePoint(point, ed), true);
            return LineRange(_box.Text, _line).Start + Math.Clamp(at < 0 ? ed.CaretIndex : at, 0, ed.Text.Length);
        }
        // The runs point into the text as it was rendered; the open line may have grown or shrunk since.
        var (line, col) = Locate(_rendered, RenderedOffsetAt(point));
        var text = _box.Text;
        if (line >= LineCount(text)) return text.Length;
        var (start, length) = LineRange(text, line);
        return start + Math.Min(col, length);
    }

    int RenderedOffsetAt(Point point)
    {
        var pointer = Viewer.GetPositionFromPoint(point, true);
        var max = _rendered.Length;
        if (pointer == null) return max;
        if (pointer.Parent is Run { Tag: int start } run)
            return Math.Clamp(start + run.ContentStart.GetOffsetToPosition(pointer), 0, max);
        if (pointer.GetAdjacentElement(LogicalDirection.Forward) is Run { Tag: int next }) return Math.Clamp(next, 0, max);
        if (pointer.GetAdjacentElement(LogicalDirection.Backward) is Run { Tag: int prev } before)
            return Math.Clamp(prev + before.Text.Length, 0, max);
        return max;
    }

    void Render()
    {
        _dirty = false;
        var atEnd = Viewer.ExtentHeight <= Viewer.ViewportHeight + 4 || Viewer.VerticalOffset + Viewer.ViewportHeight >= Viewer.ExtentHeight - 4;
        var offset = Viewer.VerticalOffset;
        _rendered = _box.Text;
        MarkdownRender.LineEdit? edit = null;
        if (_editing && _editor is { } ed)
        {
            // Rendered again around the open line (new text arrived elsewhere): it keeps its place, text and cursor.
            _line = Math.Min(_line, LineCount(_rendered) - 1);
            var (start, length) = LineRange(_rendered, _line);
            var (caret, selected) = (ed.SelectionStart, ed.SelectionLength);
            var refocus = ed.IsKeyboardFocusWithin;
            if (ed.Parent is BlockUIContainer old) old.Child = null;
            if (ed.Text != _rendered.Substring(start, length))
            {
                _editor = null; // not a change of the user's
                ed.Text = _rendered.Substring(start, length);
                _editor = ed;
            }
            edit = new MarkdownRender.LineEdit(start, start + length, ed);
            if (refocus) Focus(ed, caret, selected);
        }
        Viewer.Document = MarkdownRender.Document(_rendered, _fontSize, edit);
        if (atEnd && !_editing) Viewer.ScrollToEnd();
        else Viewer.ScrollToVerticalOffset(offset);
    }

    // ----- lines of the text: split at \n; a \r before it belongs to the break, not to the line -----

    static int LineCount(string t)
    {
        var n = 1;
        foreach (var c in t) if (c == '\n') n++;
        return n;
    }

    static (int Start, int Length) LineRange(string t, int line)
    {
        var start = 0;
        for (var i = 0; i < line; i++)
        {
            var nl = t.IndexOf('\n', start);
            if (nl < 0) return (t.Length, 0);
            start = nl + 1;
        }
        var end = t.IndexOf('\n', start);
        if (end < 0) end = t.Length;
        if (end > start && t[end - 1] == '\r') end--;
        return (start, end - start);
    }

    static (int Line, int Col) Locate(string t, int offset)
    {
        offset = Math.Clamp(offset, 0, t.Length);
        var (line, start) = (0, 0);
        for (var i = 0; i < offset; i++)
            if (t[i] == '\n') { line++; start = i + 1; }
        return (line, offset - start);
    }
}

/// <summary>Markdown blocks (<see cref="NotesMarkdown"/>) as a document in the app's own look, light or dark.</summary>
static class MarkdownRender
{
    /// <summary>A line shown as plain text to edit (from <paramref name="Start"/> to <paramref name="End"/> in the text),
    /// in place of its rendering.</summary>
    public readonly record struct LineEdit(int Start, int End, UIElement Editor);

    public static double HeadingScale(int level) => level switch { 0 => 1, 1 => 1.55, 2 => 1.32, 3 => 1.16, _ => 1.05 };

    public static FlowDocument Document(string text, double size, LineEdit? edit = null)
    {
        var doc = new FlowDocument { PagePadding = new Thickness(0), FontSize = size, LineHeight = size * 1.55 };
        doc.SetResourceReference(FlowDocument.ForegroundProperty, "Ob.Text");
        doc.SetResourceReference(FlowDocument.FontFamilyProperty, "Ob.Ui");
        var mono = (FontFamily)Application.Current.FindResource("Ob.Mono");
        var placed = edit == null;
        void PlaceEditor()
        {
            doc.Blocks.Add(new BlockUIContainer(edit!.Value.Editor) { Margin = new Thickness(0, 0, 0, size * 0.3) });
            placed = true;
        }
        foreach (var b in NotesMarkdown.Parse(text))
        {
            if (!placed && edit is { } e)
            {
                var first = b.Spans.Count > 0 ? b.Spans[0].Offset : b.Offset;
                var last = b.Spans.Count > 0 ? b.Spans[^1].Offset : b.Offset;
                if (first > e.End) PlaceEditor();
                else if (last >= e.Start)
                {
                    // The block holds the open line: what comes before it and after it stay rendered, in the block's look.
                    var before = Trim(b.Spans.Where(s => s.Offset < e.Start));
                    var after = Trim(b.Spans.Where(s => s.Offset > e.End));
                    if (before.Count > 0)
                    {
                        var p = MakeParagraph(b, before, size, mono, true);
                        p.Margin = new Thickness(p.Margin.Left, p.Margin.Top, p.Margin.Right, 0);
                        doc.Blocks.Add(p);
                    }
                    PlaceEditor();
                    if (after.Count > 0) doc.Blocks.Add(MakeParagraph(b, after, size, mono, before.Count == 0));
                    continue;
                }
            }
            doc.Blocks.Add(MakeParagraph(b, b.Spans, size, mono, true));
        }
        if (!placed) PlaceEditor();
        return doc;
    }

    /// <summary>Spans without the line breaks at either end.</summary>
    static List<MdSpan> Trim(IEnumerable<MdSpan> spans)
    {
        var list = spans.ToList();
        while (list.Count > 0 && list[0].Break) list.RemoveAt(0);
        while (list.Count > 0 && list[^1].Break) list.RemoveAt(list.Count - 1);
        return list;
    }

    /// <param name="mark">Whether a list item gets its bullet or number (not the rest of a block split by an open line).</param>
    static Paragraph MakeParagraph(MdBlock b, IReadOnlyList<MdSpan> spans, double size, FontFamily mono, bool mark)
    {
        var p = new Paragraph { Margin = new Thickness(0, 0, 0, size * 0.75) };
        switch (b.Kind)
        {
            case MdKind.Heading:
                var scale = HeadingScale(b.Level);
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
                if (mark)
                {
                    var bullet = new Run(b.Kind == MdKind.Bullet ? "•  " : b.Number + ".  ");
                    bullet.SetResourceReference(TextElement.ForegroundProperty, "Ob.Muted");
                    p.Inlines.Add(bullet);
                }
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
        foreach (var span in spans)
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
        return p;
    }
}
