using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Dictation.Core.Infrastructure;
using Dictation.Core.Notes;

namespace Dictation.App.Views;

/// <summary>
/// The dashboard's Extended Notes cell, beside the signal path: only a title and a text box. Before a session the
/// title's spot is an "Extended notes session" button with a hollow red ring (it starts one); while recording, the ring
/// is solid red (click it to stop) and the session's name is there (click to rename). The box can always be typed in:
/// while a session records it is the live transcript; between sessions it is a notepad (kept in data\notes\draft.txt)
/// that the next session begins with. Full screen opens the live session, or Extended Notes when nothing records.
/// Built once (the 3-second refresh would lose the cursor), then only updated.
/// </summary>
public partial class DashboardPage
{
    readonly NotesRecorder _notes = App.Services.Notes;
    TextBox _notesBox = null!;
    TextBlock _notesHint = null!;
    Button _notesStart = null!, _notesDot = null!, _notesTitle = null!;
    TextBox _notesTitleBox = null!;
    Ellipse _notesDotShape = null!;
    TextBlock _notesTitleText = null!;
    NotesTextBinder? _notesBinder;
    /// <summary>The box shows the draft (nothing records), not a session.</summary>
    bool _notesDraft;
    /// <summary>The session that just finished here, for the hint.</summary>
    string? _notesSaved;

    void BuildNotesCell()
    {
        var mono = (FontFamily)FindResource("Ob.Mono");
        var root = new DockPanel();

        // Header: [start button | red dot + title] ... [full screen]
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var full = new Button { Content = "⤢ FULL SCREEN", Style = (Style)FindResource("QuietButton"), FontSize = 10, Padding = new Thickness(10, 3, 10, 3),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        full.Click += (_, _) => (Window.GetWindow(this) as MainWindow)?.ShowNotes(fullScreen: true);
        DockPanel.SetDock(full, Dock.Right);
        head.Children.Add(full);

        var titleArea = new Grid { VerticalAlignment = VerticalAlignment.Center };
        _notesStart = new Button { Style = (Style)FindResource("QuietButton"), FontSize = 11, Padding = new Thickness(10, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Left,
            ToolTip = "Start an extended notes session" };
        var startContent = new StackPanel { Orientation = Orientation.Horizontal };
        var ring = new Ellipse { Width = 10, Height = 10, StrokeThickness = 1.5, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        ring.SetResourceReference(Shape.StrokeProperty, "Ob.Record");
        startContent.Children.Add(ring);
        startContent.Children.Add(new TextBlock { Text = "EXTENDED NOTES SESSION", VerticalAlignment = VerticalAlignment.Center });
        _notesStart.Content = startContent;
        System.Windows.Automation.AutomationProperties.SetName(_notesStart, "Start an extended notes session");
        _notesStart.Click += async (_, _) => await StartNotesAsync();
        titleArea.Children.Add(_notesStart);

        var live = new DockPanel { LastChildFill = true };
        _notesDot = new Button { Width = 22, Height = 22, Padding = new Thickness(0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand,
            ToolTip = "Stop the session", Margin = new Thickness(0, 0, 6, 0) };
        _notesDot.Template = PlainTemplate();
        _notesDotShape = new Ellipse { Width = 10, Height = 10, StrokeThickness = 1.5 };
        _notesDotShape.SetResourceReference(Shape.StrokeProperty, "Ob.Record");
        _notesDotShape.SetResourceReference(Shape.FillProperty, "Ob.Record");
        _notesDot.Content = _notesDotShape;
        System.Windows.Automation.AutomationProperties.SetName(_notesDot, "Stop the extended notes session");
        _notesDot.Click += async (_, _) => await _notes.StopAsync();
        DockPanel.SetDock(_notesDot, Dock.Left);
        live.Children.Add(_notesDot);
        var titleGrid = new Grid();
        _notesTitle = new Button { Background = Brushes.Transparent, BorderThickness = new Thickness(0, 0, 0, 1), Cursor = Cursors.IBeam, ToolTip = "Click to rename",
            HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(0, 1, 0, 1) };
        _notesTitle.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
        _notesTitle.Template = PlainTemplate(withBorder: true);
        _notesTitleText = new TextBlock { FontFamily = mono, FontSize = 13, FontWeight = FontWeights.Bold, TextTrimming = TextTrimming.CharacterEllipsis };
        _notesTitle.Content = _notesTitleText;
        _notesTitle.Click += (_, _) =>
        {
            if (_notes.Current is not { } s) return;
            _notesTitleBox.Text = s.Title;
            _notesTitle.Visibility = Visibility.Collapsed;
            _notesTitleBox.Visibility = Visibility.Visible;
            _notesTitleBox.Focus();
            _notesTitleBox.SelectAll();
        };
        titleGrid.Children.Add(_notesTitle);
        _notesTitleBox = new TextBox { FontFamily = mono, FontSize = 13, FontWeight = FontWeights.Bold, Visibility = Visibility.Collapsed };
        System.Windows.Automation.AutomationProperties.SetName(_notesTitleBox, "Session name");
        void CommitTitle()
        {
            if (_notesTitleBox.Visibility != Visibility.Visible) return;
            if (_notes.Current is { } s && _notesTitleBox.Text.Trim().Length > 0 && _notesTitleBox.Text.Trim() != s.Title)
            {
                s.Title = _notesTitleBox.Text.Trim();
                App.Services.NotesStore.Save(s);
            }
            _notesTitleBox.Visibility = Visibility.Collapsed;
            _notesTitle.Visibility = Visibility.Visible;
            UpdateNotesCell();
        }
        _notesTitleBox.LostKeyboardFocus += (_, _) => CommitTitle();
        _notesTitleBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) { CommitTitle(); e.Handled = true; }
            else if (e.Key == Key.Escape) { _notesTitleBox.Text = _notes.Current?.Title ?? ""; CommitTitle(); e.Handled = true; }
        };
        titleGrid.Children.Add(_notesTitleBox);
        live.Children.Add(titleGrid);
        live.Tag = "live";
        titleArea.Children.Add(live);
        head.Children.Add(titleArea);
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        // The text box: always editable (the live transcript, or the draft between sessions); a hint while it's empty
        var boxArea = new Grid();
        _notesBox = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = 13, Padding = new Thickness(8, 6, 8, 6), VerticalContentAlignment = VerticalAlignment.Top };
        System.Windows.Automation.AutomationProperties.SetName(_notesBox, "Extended notes");
        _notesBox.TextChanged += (_, _) =>
        {
            if (_notesDraft) App.Services.NotesStore.SetDraft(_notesBox.Text);
            _notesHint.Visibility = _notesBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        };
        boxArea.Children.Add(_notesBox);
        // Read as Markdown; a click (or typing) turns it back into the plain box to edit.
        _ = new MarkdownPresenter(_notesBox, 13);
        _notesHint = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 9, 12, 0), FontSize = 12.5, IsHitTestVisible = false };
        _notesHint.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        boxArea.Children.Add(_notesHint);
        root.Children.Add(boxArea);

        NotesCell.Child = root;
    }

    void AttachNotes()
    {
        _notes.StateChanged -= UpdateNotesCell;
        _notes.StateChanged += UpdateNotesCell;
        UpdateNotesCell();
    }

    void DetachNotes()
    {
        _notes.StateChanged -= UpdateNotesCell;
        UnbindNotes();
        _notesDraft = false;
    }

    static ControlTemplate PlainTemplate(bool withBorder = false)
    {
        var t = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        if (withBorder)
        {
            border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
            border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
            border.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        }
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, withBorder ? HorizontalAlignment.Left : HorizontalAlignment.Center);
        border.AppendChild(content);
        t.VisualTree = border;
        return t;
    }

    async Task StartNotesAsync()
    {
        _notesStart.IsEnabled = false;
        try { await _notes.StartAsync(App.Services.Settings.Current.NotesSource); }
        catch (UserFacingException ex) { MessageBox.Show(ex.Message, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning); }
        catch (Exception ex)
        {
            Log.Error("Starting extended notes failed", ex);
            MessageBox.Show("Extended notes couldn't start. See the log for details.", AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { _notesStart.IsEnabled = true; UpdateNotesCell(); }
    }

    /// <summary>Show the cell for the current state: idle (start button, the draft) or recording (dot, title, live text).</summary>
    void UpdateNotesCell()
    {
        if (_notesBox == null) return;
        var s = _notes.Current;
        var recording = s != null;
        _notesStart.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        var live = ((Grid)_notesStart.Parent).Children.OfType<DockPanel>().First();
        live.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        if (recording && _notesTitleBox.Visibility != Visibility.Visible) _notesTitleText.Text = s!.Title.ToUpperInvariant();
        if (recording && !_notes.IsPaused && !_notes.IsFinishing) _notesDotShape.SetResourceReference(Shape.FillProperty, "Ob.Record");
        else _notesDotShape.Fill = Brushes.Transparent;
        _notesDot.ToolTip = _notes.IsFinishing ? "Finishing…" : "Stop the session";
        _notesDot.IsEnabled = !_notes.IsFinishing;

        if (recording && _notesBinder?.Session != s)
        {
            // A session started (it took the draft): the box is its transcript now.
            UnbindNotes();
            _notesDraft = false;
            _notesBinder = new NotesTextBinder(_notesBox, s!, NoteDoc.Transcript);
        }
        else if (!recording && !_notesDraft)
        {
            // Nothing records: the box is a notepad again, for the next session.
            if (_notesBinder != null) _notesSaved = _notesBinder.Session.Title;
            UnbindNotes();
            _notesBox.Text = App.Services.NotesStore.Draft;
            _notesDraft = true;
        }
        _notesHint.Text = recording
            ? (_notes.IsPaused ? "Paused. You can still type your own notes here." : "Listening. The transcript appears here, and you can type your own notes in it anytime.")
            : (_notesSaved != null ? $"“{_notesSaved}” is saved in Extended Notes. " : "") +
              "Type here anytime: what you type begins the next session, and its transcript follows.";
        _notesHint.Visibility = _notesBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void UnbindNotes()
    {
        _notesBinder?.Dispose();
        _notesBinder = null;
    }
}
