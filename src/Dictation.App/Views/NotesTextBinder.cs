using System.Windows.Controls;
using Dictation.Core.Notes;

namespace Dictation.App.Views;

/// <summary>
/// Keeps a text box and one text of an Extended Notes session in step, both ways: what the user types goes into the
/// session, and what arrives (a new piece of speech, the AI's formatting, an edit in another box) goes into the box
/// without moving the user's cursor. New text at the end keeps the box scrolled to the end if it was there.
/// </summary>
sealed class NotesTextBinder : IDisposable
{
    readonly TextBox _box;
    readonly NoteSession _session;
    readonly NoteDoc _doc;
    bool _updating;

    public NotesTextBinder(TextBox box, NoteSession session, NoteDoc doc)
    {
        _box = box; _session = session; _doc = doc;
        _updating = true;
        _box.Text = session.Get(doc);
        _updating = false;
        _box.TextChanged += OnBox;
        _session.Changed += OnSession;
        _box.Dispatcher.BeginInvoke(() => _box.ScrollToEnd());
    }

    public NoteSession Session => _session;

    void OnBox(object sender, TextChangedEventArgs e)
    {
        if (_updating) return;
        _session.Set(_doc, _box.Text, this);
    }

    void OnSession(NoteDoc doc, object? source)
    {
        if (doc != _doc || ReferenceEquals(source, this)) return;
        var now = _session.Get(_doc);
        var old = _box.Text;
        if (now == old) return;
        var atEnd = _box.VerticalOffset + _box.ViewportHeight >= _box.ExtentHeight - 4;
        _updating = true;
        try
        {
            if (now.StartsWith(old, StringComparison.Ordinal)) _box.AppendText(now[old.Length..]); // keeps the caret and selection
            else
            {
                var caret = _box.CaretIndex;
                var offset = _box.VerticalOffset;
                _box.Text = now;
                _box.CaretIndex = Math.Min(caret, now.Length);
                _box.ScrollToVerticalOffset(offset);
            }
        }
        finally { _updating = false; }
        if (atEnd) _box.ScrollToEnd();
    }

    public void Dispose()
    {
        _box.TextChanged -= OnBox;
        _session.Changed -= OnSession;
    }
}
