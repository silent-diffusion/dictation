using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Dictation.App.Services;
using Dictation.Core.Infrastructure;
using Dictation.Core.Notes;

namespace Dictation.App.Views;

/// <summary>
/// Extended Notes: the landing page (start a session, the sessions so far) and a session (Transcript, Formatted,
/// Summary and Edited, the recording at the bottom, Export). Every view is a plain text box; the Edited tab colours the
/// AI's changes and the user's apart.
/// </summary>
public partial class NotesPage : UserControl
{
    readonly NotesRecorder _recorder = App.Services.Notes;
    readonly NotesStore _store = App.Services.NotesStore;
    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(400) };
    readonly MediaPlayer _player = new();
    readonly List<NotesTextBinder> _binders = new();
    NoteSession? _session;
    NoteDoc _tab = NoteDoc.Transcript;
    bool _edited, _playing, _seeking, _playerOpen, _preparing, _prepareFailed, _autoPlay;
    bool _editedDirty = true; // the session changed since the Edited tab was last built
    PreparedAudio? _prepared;
    readonly DispatcherTimer _skipTick = new() { Interval = TimeSpan.FromMilliseconds(120) };
    DateTime _editedBuilt = DateTime.MinValue;
    int _lastPlayCaret = -1;
    double? _pendingSeek;

    public NotesPage()
    {
        InitializeComponent();
        (App.Services.Settings.Current.NotesSource switch
        {
            NotesSource.Computer => ComputerSource,
            NotesSource.Both => BothSource,
            _ => MicSource,
        }).IsChecked = true;
        TranscriptTab.IsChecked = true;
        BuildLegend();
        _recorder.StateChanged += OnRecorder;
        _store.Sessions.CollectionChanged += OnSessions;
        _tick.Tick += (_, _) => Refresh();
        _skipTick.Tick += (_, _) => SkipTick();
        _player.MediaOpened += (_, _) => OnPlayerOpened();
        _player.MediaEnded += (_, _) => PausePlayback();
        AttachJump(TranscriptBox, NoteDoc.Transcript);
        AttachJump(FormattedBox, NoteDoc.Formatted);
        AttachJump(SummaryBox, NoteDoc.Summary);
        AttachJumpEdited();
        Loaded += (_, _) => { _tick.Start(); ShowLanding(); };
        Unloaded += (_, _) =>
        {
            _tick.Stop();
            _recorder.StateChanged -= OnRecorder;
            _store.Sessions.CollectionChanged -= OnSessions;
            ClosePlayer();
            Unbind();
        };
    }

    // ===== landing =====

    public void ShowLanding()
    {
        ClosePlayer();
        Unbind();
        _session = null;
        SessionView.Visibility = Visibility.Collapsed;
        Landing.Visibility = Visibility.Visible;
        ShowStart();
        BuildUsage();
        BuildList();
    }

    void OnSessions(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (Landing.IsVisible) { BuildUsage(); BuildList(); }
    }

    void ShowStart()
    {
        var live = _recorder.Current;
        StartText.Text = live == null ? "EXTENDED NOTES SESSION" : "● RECORDING // " + live.Title.ToUpperInvariant() + " // OPEN";
        if (live == null) { StartRing.Fill = Brushes.Transparent; }
        else StartRing.SetResourceReference(Shape.FillProperty, "Ob.Record");
        MicSource.IsEnabled = ComputerSource.IsEnabled = BothSource.IsEnabled = live == null;
    }

    NotesSource ChosenSource => ComputerSource.IsChecked == true ? NotesSource.Computer : BothSource.IsChecked == true ? NotesSource.Both : NotesSource.Mic;

    void Source_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        App.Services.Settings.Current.NotesSource = ChosenSource;
        App.Services.Settings.Save();
    }

    async void Start_Click(object sender, RoutedEventArgs e)
    {
        if (_recorder.Current is { } live) { Open(live); return; }
        StartButton.IsEnabled = false;
        try
        {
            await _recorder.StartAsync(ChosenSource);
            if (_recorder.Current is { } s) Open(s);
        }
        catch (UserFacingException ex) { MessageBox.Show(ex.Message, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning); }
        catch (Exception ex)
        {
            Log.Error("Starting extended notes failed", ex);
            MessageBox.Show("Extended notes couldn't start. See the log for details.", AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { StartButton.IsEnabled = true; ShowStart(); }
    }

    void Search_Changed(object sender, TextChangedEventArgs e) => BuildList();

    void BuildList()
    {
        SessionList.Children.Clear();
        var q = SearchBox.Text.Trim();
        var sessions = _store.Sessions.Where(s => q.Length == 0
            || s.Title.Contains(q, StringComparison.OrdinalIgnoreCase)
            || s.Transcript.Contains(q, StringComparison.OrdinalIgnoreCase)
            || s.Summary.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
        if (sessions.Count == 0)
        {
            SessionList.Children.Add(new TextBlock
            {
                Text = q.Length > 0 ? "No session matches." : "No sessions yet. Start one above and it appears here.",
                Style = (Style)FindResource("Caption"), Margin = new Thickness(2, 6, 0, 0),
            });
            return;
        }
        foreach (var s in sessions) SessionList.Children.Add(Row(s));
    }

    FrameworkElement Row(NoteSession s)
    {
        var live = ReferenceEquals(s, _recorder.Current);
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2.4, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.7, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.9, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
        name.Children.Add(new TextBlock { Text = s.Title, FontFamily = Mono, FontSize = 13, FontWeight = FontWeights.Bold, TextTrimming = TextTrimming.CharacterEllipsis });
        var gist = new TextBlock { Text = Gist(s), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 0) };
        gist.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        name.Children.Add(gist);
        grid.Children.Add(name);
        Cell(grid, 1, s.Started.Date == DateTime.Today ? "Today " + s.Started.ToString("t") : s.Started.ToString("d MMM, t"));
        Cell(grid, 2, Length(s.Seconds));
        Cell(grid, 3, s.Source switch { NotesSource.Computer => "COMPUTER AUDIO", NotesSource.Both => "MIC + COMPUTER", _ => "MIC" }, small: true);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (live)
        {
            var rec = new TextBlock { Text = "● RECORDING", FontFamily = Mono, FontSize = 10.5, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center };
            rec.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Record");
            actions.Children.Add(rec);
        }
        else
        {
            var delete = new Button { Content = "DELETE", Style = (Style)FindResource("QuietButton"), FontSize = 10, Padding = new Thickness(10, 3, 10, 3) };
            delete.Click += (_, e) =>
            {
                e.Handled = true;
                if (MessageBox.Show($"Delete \"{s.Title}\" with its recording? This can't be undone.", AppInfo.Name,
                        MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes) _store.Delete(s);
            };
            actions.Children.Add(delete);
        }
        Grid.SetColumn(actions, 4);
        grid.Children.Add(actions);

        var row = new Border { Child = grid, Padding = new Thickness(6, 10, 6, 10), BorderThickness = new Thickness(0, 0, 0, 1), Cursor = Cursors.Hand, Background = Brushes.Transparent };
        row.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
        row.MouseEnter += (_, _) => row.SetResourceReference(Border.BackgroundProperty, "Ob.Hover");
        row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
        row.MouseLeftButtonUp += (_, _) => Open(s);
        return row;
    }

    void Cell(Grid grid, int column, string text, bool small = false)
    {
        var t = new TextBlock { Text = text, FontFamily = Mono, FontSize = small ? 10.5 : 11.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        if (small) t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        Grid.SetColumn(t, column);
        grid.Children.Add(t);
    }

    static string Gist(NoteSession s)
    {
        var text = s.Summary.Trim().Length > 0 ? s.Summary : s.Formatted.Trim().Length > 0 ? s.Formatted : s.Transcript;
        text = text.ReplaceLineEndings(" ").Trim();
        return text.Length == 0 ? "Nothing transcribed yet." : text.Length > 140 ? text[..140].TrimEnd() + "…" : text;
    }

    static string Length(double seconds)
    {
        var t = TimeSpan.FromSeconds(seconds);
        return $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}";
    }

    FontFamily Mono => (FontFamily)FindResource("Ob.Mono");

    // ----- the USAGE strip: the counts so far -----

    /// <summary>The counts in data\notes\usage.json (sessions, time, words, AI requests, by source; never any text) over
    /// the last 30 days and all time. Hidden until a session has been counted: a page of zeros says nothing.</summary>
    void BuildUsage()
    {
        UsageRows.Children.Clear();
        var now = DateTime.Now;
        var all = _store.Usage.Totals(now, 0);
        if (all.Sessions == 0) { UsageStrip.Visibility = Visibility.Collapsed; return; }
        UsageStrip.Visibility = Visibility.Visible;
        UsageRows.Children.Add(UsageRow("USAGE // LAST 30 DAYS", _store.Usage.Totals(now, 30)));
        UsageRows.Children.Add(new Border { Style = (Style)FindResource("Divider"), Margin = new Thickness(0, 8, 0, 8) });
        UsageRows.Children.Add(UsageRow("ALL TIME", all));
    }

    FrameworkElement UsageRow(string label, NotesUsageTotals totals)
    {
        var row = new DockPanel();
        var head = new TextBlock { Text = label, Style = (Style)FindResource("MonoLabel"), Width = 170, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(head, Dock.Left);
        row.Children.Add(head);
        var readouts = new WrapPanel { VerticalAlignment = VerticalAlignment.Center };
        readouts.Children.Add(UsageReadout(totals.Sessions.ToString("N0"), totals.Sessions == 1 ? "SESSION" : "SESSIONS"));
        readouts.Children.Add(UsageReadout(NotesUsage.HoursMinutes(totals.Seconds), "RECORDED"));
        readouts.Children.Add(UsageReadout(totals.WordsHeard.ToString("N0"), "WORDS HEARD"));
        readouts.Children.Add(UsageReadout(totals.WordsTyped.ToString("N0"), "WORDS TYPED"));
        readouts.Children.Add(UsageReadout(totals.AiRequests.ToString("N0"), "AI REQUESTS"));
        // By source, in the order of the pills above, only the ones used: "MIC 3 · COMPUTER 1 · BOTH 2"
        var by = UsageText();
        foreach (var source in new[] { NotesSource.Mic, NotesSource.Computer, NotesSource.Both })
        {
            var n = totals.Sources.GetValueOrDefault(source.ToString());
            if (n == 0) continue;
            if (by.Inlines.Count > 0) by.Inlines.Add(new Run(" · "));
            by.Inlines.Add(new Run(source.ToString().ToUpperInvariant() + " "));
            by.Inlines.Add(UsageNumber(n.ToString("N0")));
        }
        readouts.Children.Add(by);
        row.Children.Add(readouts);
        return row;
    }

    /// <summary>One readout: the number in bold ink, its label small and muted, on one baseline.</summary>
    TextBlock UsageReadout(string value, string label)
    {
        var t = UsageText();
        t.Inlines.Add(UsageNumber(value));
        t.Inlines.Add(new Run(" " + label));
        return t;
    }

    /// <summary>The small muted mono text a readout is set in.</summary>
    TextBlock UsageText()
    {
        var t = new TextBlock { FontFamily = Mono, FontSize = 10.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 22, 0) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        return t;
    }

    static Run UsageNumber(string value)
    {
        var r = new Run(value) { FontSize = 13, FontWeight = FontWeights.Bold };
        r.SetResourceReference(TextElement.ForegroundProperty, "Ob.Text");
        return r;
    }

    void BackToList_Click(object sender, RoutedEventArgs e) => ShowLanding();

    // ===== a session =====

    /// <summary>Show a session: the live one, or one from the list.</summary>
    public void Open(NoteSession s)
    {
        if (!IsLoaded) { Loaded += OpenWhenLoaded; _openWhenLoaded = s; return; }
        ClosePlayer();
        Unbind();
        _session = s;
        Landing.Visibility = Visibility.Collapsed;
        SessionView.Visibility = Visibility.Visible;
        _binders.Add(new NotesTextBinder(TranscriptBox, s, NoteDoc.Transcript));
        _binders.Add(new NotesTextBinder(FormattedBox, s, NoteDoc.Formatted));
        _binders.Add(new NotesTextBinder(SummaryBox, s, NoteDoc.Summary));
        s.Changed += OnSessionChanged;
        TitleText.Text = s.Title.ToUpperInvariant();
        TitleBox.Visibility = Visibility.Collapsed;
        TitleButton.Visibility = Visibility.Visible;
        _lastPlayCaret = -1;
        Seek.Value = 0;
        _editedBuilt = DateTime.MinValue;
        _editedDirty = true;
        if (_edited) BuildEdited();
        Refresh();
    }

    NoteSession? _openWhenLoaded;
    void OpenWhenLoaded(object sender, RoutedEventArgs e)
    {
        Loaded -= OpenWhenLoaded;
        if (_openWhenLoaded is { } s) Dispatcher.BeginInvoke(() => Open(s), DispatcherPriority.Loaded);
        _openWhenLoaded = null;
    }

    void Unbind()
    {
        foreach (var b in _binders) b.Dispose();
        _binders.Clear();
        if (_session != null) _session.Changed -= OnSessionChanged;
    }

    void OnSessionChanged(NoteDoc doc, object? source)
    {
        _editedDirty = true;
        // The recorder saves its own changes; the user's edits are saved here, a moment after they stop typing.
        if (_session != null && !ReferenceEquals(source, _recorder) && !ReferenceEquals(_session, _recorder.Current)) _saveSoon = DateTime.Now.AddSeconds(2);
    }

    DateTime? _saveSoon;

    void OnRecorder()
    {
        if (Landing.IsVisible) { ShowStart(); BuildUsage(); return; } // a session that just stopped is counted now
        Refresh();
    }

    bool Live => _session != null && ReferenceEquals(_session, _recorder.Current);

    void Refresh()
    {
        if (_saveSoon is { } due && DateTime.Now >= due && _session != null) { _store.Save(_session); _saveSoon = null; }
        if (_session == null || !SessionView.IsVisible) return;
        var live = Live;
        if (TitleBox.Visibility != Visibility.Visible) TitleText.Text = _session.Title.ToUpperInvariant();
        PauseButton.Visibility = StopButton.Visibility = live ? Visibility.Visible : Visibility.Collapsed;
        PauseButton.Content = _recorder.UserPaused ? "● RESUME" : "Ⅱ PAUSE";
        StopButton.IsEnabled = PauseButton.IsEnabled = !_recorder.IsFinishing;
        if (live && !_recorder.IsPaused && !_recorder.IsFinishing) RecDot.SetResourceReference(Shape.FillProperty, "Ob.Record");
        else RecDot.Fill = Brushes.Transparent;
        RecDot.Visibility = live ? Visibility.Visible : Visibility.Collapsed;
        var seconds = live ? _recorder.Seconds : _session.Seconds;
        var state = !live ? "" : _recorder.IsFinishing ? "  // FINISHING…" : _recorder.UserPaused ? "  // PAUSED"
            : _recorder.IsPaused ? "  // PAUSED WHILE YOU DICTATE" : !_recorder.Transcribing ? "  // CONNECTING…" : "";
        TimerText.Text = Length(seconds) + state;
        if (live) TimerText.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        else TimerText.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        FullButton.Content = Owner?.IsFullScreen == true ? "⤡ EXIT FULL SCREEN" : "⤢ FULL SCREEN";
        // The recording can be played once the session has stopped.
        PlayBar.Visibility = live ? Visibility.Collapsed : Visibility.Visible;
        if (!live)
        {
            if (_prepared == null && !_preparing && !_playerOpen) PreparePlayback();
            UpdatePlayer(seconds);
        }
        if (_edited && live && _editedDirty && DateTime.Now - _editedBuilt > TimeSpan.FromSeconds(4)) BuildEdited();
    }

    MainWindow? Owner => Window.GetWindow(this) as MainWindow;

    void Pause_Click(object sender, RoutedEventArgs e)
    {
        if (_recorder.UserPaused) _recorder.Resume(); else _recorder.Pause();
        Refresh();
    }

    async void Stop_Click(object sender, RoutedEventArgs e)
    {
        StopButton.IsEnabled = false;
        await _recorder.StopAsync();
        Refresh();
    }

    void Full_Click(object sender, RoutedEventArgs e)
    {
        if (Owner is { } w) w.SetFullScreen(!w.IsFullScreen);
        Refresh();
    }

    // ----- title: click to rename -----

    void Title_Click(object sender, RoutedEventArgs e)
    {
        if (_session == null) return;
        TitleBox.Text = _session.Title;
        TitleButton.Visibility = Visibility.Collapsed;
        TitleBox.Visibility = Visibility.Visible;
        TitleBox.Focus();
        TitleBox.SelectAll();
    }

    void TitleBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { CommitTitle(); e.Handled = true; }
        else if (e.Key == Key.Escape) { TitleBox.Text = _session?.Title ?? ""; CommitTitle(); e.Handled = true; }
    }

    void TitleBox_LostFocus(object sender, KeyboardFocusChangedEventArgs e) => CommitTitle();

    void CommitTitle()
    {
        if (_session == null || TitleBox.Visibility != Visibility.Visible) return;
        var title = TitleBox.Text.Trim();
        if (title.Length > 0 && title != _session.Title)
        {
            _session.Title = title;
            _store.Save(_session);
        }
        TitleText.Text = _session.Title.ToUpperInvariant();
        TitleBox.Visibility = Visibility.Collapsed;
        TitleButton.Visibility = Visibility.Visible;
    }

    // ----- tabs -----

    void Tab_Checked(object sender, RoutedEventArgs e)
    {
        _edited = EditedTab.IsChecked == true;
        _tab = FormattedTab.IsChecked == true ? NoteDoc.Formatted : SummaryTab.IsChecked == true ? NoteDoc.Summary : NoteDoc.Transcript;
        TranscriptBox.Visibility = !_edited && _tab == NoteDoc.Transcript ? Visibility.Visible : Visibility.Collapsed;
        FormattedBox.Visibility = !_edited && _tab == NoteDoc.Formatted ? Visibility.Visible : Visibility.Collapsed;
        SummaryBox.Visibility = !_edited && _tab == NoteDoc.Summary ? Visibility.Visible : Visibility.Collapsed;
        EditedPanel.Visibility = _edited ? Visibility.Visible : Visibility.Collapsed;
        TabHint.Text = _edited ? "EVERY CHANGE, IN COLOUR // READ ONLY"
            : _tab switch
            {
                NoteDoc.Formatted => "TIDIED BY THE AI ABOUT EVERY MINUTE // YOUR EDITS STAY",
                NoteDoc.Summary => "MAIN IDEA, KEY POINTS, THREE PARAGRAPHS AT MOST // EVERY 5–10 MINUTES // EDIT FREELY",
                _ => "WORD FOR WORD, AS IT IS HEARD // TYPE ANYWHERE TO ADD YOUR NOTES",
            };
        if (_edited && _session != null) BuildEdited();
    }

    // ----- the Edited tab -----

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }
    static Brush UserInk => ThemeManager.IsDark ? Frozen(Color.FromRgb(0xFF, 0xB3, 0x47)) : Frozen(Color.FromRgb(0x8A, 0x4B, 0x00));
    static Brush UserWash => ThemeManager.IsDark ? Frozen(Color.FromArgb(0x29, 0xFF, 0xB3, 0x47)) : Frozen(Color.FromArgb(0x1F, 0x8A, 0x4B, 0x00));

    void BuildEdited()
    {
        if (_session == null) return;
        _editedBuilt = DateTime.Now;
        _editedDirty = false;
        IReadOnlyList<EditPiece> pieces;
        try { pieces = NotesEdits.Build(_session); }
        catch (Exception e) { Log.Error("Building the Edited view failed", e); return; }
        var offset = EditedBox.VerticalOffset;
        var doc = new FlowDocument { PagePadding = new Thickness(0), FontSize = 14.5, LineHeight = 24 };
        doc.SetResourceReference(FlowDocument.ForegroundProperty, "Ob.Text");
        var para = new Paragraph { Margin = new Thickness(0, 0, 0, 12) };
        var user = UserInk;
        var wash = UserWash;
        // Neighbouring words with the same mark become one run (an hour of notes stays quick to show).
        EditMark? mark = null;
        double at = 0; // when the run's first word was said (the right-click jump)
        var run = new System.Text.StringBuilder();
        void Flush()
        {
            if (mark == null || run.Length == 0) { run.Clear(); return; }
            var r = Styled(run.ToString(), mark.Value, user, wash);
            r.Tag = at;
            para.Inlines.Add(r);
            para.Inlines.Add(new Run(" ") { Tag = at });
            run.Clear();
        }
        foreach (var p in pieces)
        {
            if (p.Mark is EditMark.Paragraph or EditMark.AiParagraph)
            {
                Flush();
                if (p.Mark == EditMark.AiParagraph)
                {
                    var pilcrow = new Run("¶") { FontWeight = FontWeights.Bold, Tag = p.Seconds };
                    pilcrow.SetResourceReference(TextElement.ForegroundProperty, "Ob.Accent");
                    para.Inlines.Add(pilcrow);
                }
                if (para.Inlines.Count > 0) { doc.Blocks.Add(para); para = new Paragraph { Margin = new Thickness(0, 0, 0, 12) }; }
                mark = null;
                continue;
            }
            if (mark != p.Mark) { Flush(); mark = p.Mark; at = p.Seconds; }
            if (run.Length > 0) run.Append(' ');
            run.Append(p.Text);
        }
        Flush();
        if (para.Inlines.Count > 0) doc.Blocks.Add(para);
        if (doc.Blocks.Count == 0)
        {
            var empty = new Paragraph(new Run("Nothing yet: changes show here once the AI has formatted some text or you have edited it."));
            empty.SetResourceReference(TextElement.ForegroundProperty, "Ob.Muted");
            doc.Blocks.Add(empty);
        }
        EditedBox.Document = doc;
        EditedBox.ScrollToVerticalOffset(offset);
    }

    static Run Styled(string text, EditMark mark, Brush user, Brush wash)
    {
        var r = new Run(text);
        switch (mark)
        {
            case EditMark.AiRemoved:
                r.TextDecorations = TextDecorations.Strikethrough;
                r.SetResourceReference(TextElement.ForegroundProperty, "Ob.Muted");
                break;
            case EditMark.AiAdded:
                r.SetResourceReference(TextElement.ForegroundProperty, "Ob.Accent");
                break;
            case EditMark.UserRemoved:
                r.Foreground = user;
                r.TextDecorations = new TextDecorationCollection { new TextDecoration(TextDecorationLocation.Strikethrough, new Pen(user, 2), 0, TextDecorationUnit.FontRecommended, TextDecorationUnit.FontRecommended) };
                break;
            case EditMark.UserChanged:
                r.Foreground = user;
                r.FontWeight = FontWeights.Bold;
                r.Background = wash;
                break;
            case EditMark.UserNote:
                r.Foreground = user;
                r.FontWeight = FontWeights.Bold;
                r.TextDecorations = TextDecorations.Underline;
                break;
        }
        return r;
    }

    void BuildLegend()
    {
        void Add(string text, EditMark mark)
        {
            var t = new TextBlock { FontFamily = (FontFamily)FindResource("Ob.Mono"), FontSize = 10.5, Margin = new Thickness(0, 0, 18, 4) };
            t.Inlines.Add(Styled(text, mark, UserInk, UserWash));
            Legend.Children.Add(t);
        }
        Add("REMOVED BY AI", EditMark.AiRemoved);
        Add("ADDED BY AI", EditMark.AiAdded);
        var p = new TextBlock { FontFamily = (FontFamily)FindResource("Ob.Mono"), FontSize = 10.5, Margin = new Thickness(0, 0, 18, 4), Text = "¶ PARAGRAPH BREAK BY AI" };
        p.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        Legend.Children.Add(p);
        Add("REMOVED BY YOU", EditMark.UserRemoved);
        Add("CHANGED BY YOU", EditMark.UserChanged);
        Add("NOTE TYPED BY YOU", EditMark.UserNote);
    }

    // ----- export -----

    void Export_Click(object sender, RoutedEventArgs e)
    {
        if (_session == null) return;
        var menu = new ContextMenu { PlacementTarget = ExportButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        void Item(string header, Action action)
        {
            var mi = new MenuItem { Header = header };
            mi.Click += (_, _) => action();
            menu.Items.Add(mi);
        }
        Item("Transcript (.txt)", () => SaveText(NotesExport.Part.Transcript, false));
        Item("Formatted (.txt)", () => SaveText(NotesExport.Part.Formatted, false));
        Item("Summary (.txt)", () => SaveText(NotesExport.Part.Summary, false));
        Item("Everything (.md)", () => SaveText(NotesExport.Part.Everything, true));
        Item("Everything (.txt)", () => SaveText(NotesExport.Part.Everything, false));
        menu.Items.Add(new Separator());
        Item("Recording (.wav)", SaveAudio);
        menu.IsOpen = true;
    }

    string SafeName => string.Join("_", (_session?.Title ?? "Extended notes").Split(System.IO.Path.GetInvalidFileNameChars())).Trim();

    void SaveText(NotesExport.Part part, bool markdown)
    {
        if (_session == null) return;
        var name = part == NotesExport.Part.Everything ? SafeName : $"{SafeName} - {part}";
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            FileName = name, DefaultExt = markdown ? ".md" : ".txt",
            Filter = markdown ? "Markdown (*.md)|*.md" : "Text (*.txt)|*.txt",
        };
        if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
        try { File.WriteAllText(dlg.FileName, NotesExport.Build(_session, part, markdown)); }
        catch (Exception ex) { MessageBox.Show("Saving failed: " + ex.Message, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    void SaveAudio()
    {
        if (_session == null || !File.Exists(_session.AudioPath)) return;
        var dlg = new Microsoft.Win32.SaveFileDialog { FileName = SafeName, DefaultExt = ".wav", Filter = "WAV audio (*.wav)|*.wav" };
        if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
        // As played: with its level brought up, once the recording has been prepared.
        var source = _prepared != null && File.Exists(_prepared.Path) ? _prepared.Path : _session.AudioPath;
        try { CopyRecording(source, dlg.FileName); }
        catch (Exception ex) { MessageBox.Show("Saving failed: " + ex.Message, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    /// <summary>Copy the recording, also while it is still being written (the writer lets others read).</summary>
    static void CopyRecording(string from, string to)
    {
        using var src = new FileStream(from, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var dst = new FileStream(to, FileMode.Create, FileAccess.Write);
        src.CopyTo(dst);
    }

    // ----- playback: once the session has stopped; from where the cursor is -----

    TextBox? ActiveBox => _edited ? null : _tab switch { NoteDoc.Formatted => FormattedBox, NoteDoc.Summary => null, _ => TranscriptBox };

    /// <summary>Make the recording ready to play (its level brought up, its pauses found) in the background, and open
    /// the player on the result. Mic recordings are often very quiet, so this comes before the first play. The copy is
    /// made once per session and kept in the temp folder, so the next time it opens it is ready at once.</summary>
    async void PreparePlayback()
    {
        if (_session == null || Live || _preparing || _prepared != null || _prepareFailed || !File.Exists(_session.AudioPath)) return;
        var session = _session;
        _preparing = true;
        UpdatePlayer(session.Seconds);
        try
        {
            var prepared = await Task.Run(() => NotesAudio.PrepareCached(session.AudioPath, session.Id));
            if (!ReferenceEquals(session, _session) || !SessionView.IsVisible || _prepared != null) return;
            _prepared = prepared;
            _player.Open(new Uri(prepared.Path));
            _playerOpen = true;
        }
        catch (Exception ex)
        {
            Log.Warn("Extended notes: couldn't prepare the recording: " + ex.Message);
            _prepareFailed = true;
        }
        finally
        {
            _preparing = false;
            UpdatePlayer(_session?.Seconds ?? 0);
        }
    }

    void Play_Click(object sender, RoutedEventArgs e)
    {
        if (_session == null || Live) return;
        if (_playing) { PausePlayback(); return; }
        if (!_playerOpen) { _autoPlay = true; PreparePlayback(); return; }
        // Where to start: the moment the text at the cursor was said, if the cursor moved since the last play.
        if (ActiveBox is { } box && box.CaretIndex != _lastPlayCaret)
        {
            _lastPlayCaret = box.CaretIndex;
            _player.Position = TimeSpan.FromSeconds(_session.SecondsAt(_tab, box.CaretIndex));
        }
        StartPlayback();
    }

    /// <summary>Jump to a moment in the recording and play from there (the right-click menus).</summary>
    void PlayFrom(double seconds)
    {
        if (_session == null || Live) return;
        _lastPlayCaret = ActiveBox?.CaretIndex ?? -1;
        if (!_playerOpen) { _pendingSeek = seconds; _autoPlay = true; PreparePlayback(); return; }
        _player.Position = TimeSpan.FromSeconds(seconds);
        StartPlayback();
    }

    void StartPlayback()
    {
        _player.SpeedRatio = Speed;
        _player.Play();
        _playing = true;
        if (SkipSilences.IsChecked == true) _skipTick.Start();
        ShowPlay();
    }

    void PausePlayback()
    {
        _player.Pause();
        _playing = false;
        _skipTick.Stop();
        ShowPlay();
    }

    void OnPlayerOpened()
    {
        if (_pendingSeek is { } s) _player.Position = TimeSpan.FromSeconds(s);
        _pendingSeek = null;
        _player.SpeedRatio = Speed;
        if (_autoPlay) { _autoPlay = false; StartPlayback(); }
        UpdatePlayer(_session?.Seconds ?? 0);
    }

    /// <summary>While "skip silences" is on: over a pause, jump to just before its end.</summary>
    void SkipTick()
    {
        if (!_playing || _prepared == null) return;
        var pos = _player.Position.TotalSeconds;
        if (_prepared.SilenceAt(pos) is { } gap && gap.End - pos > NotesAudio.KeepGap)
            _player.Position = TimeSpan.FromSeconds(gap.End - NotesAudio.KeepGap);
    }

    void Skip_Changed(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        if (_playing && SkipSilences.IsChecked == true) _skipTick.Start(); else _skipTick.Stop();
    }

    double Speed => Speed2.IsChecked == true ? 2.0 : Speed15.IsChecked == true ? 1.5 : 1.0;

    void Speed_Checked(object sender, RoutedEventArgs e)
    {
        if (IsLoaded && _playerOpen) _player.SpeedRatio = Speed;
    }

    void ShowPlay() => PlayGlyph.Text = _playing ? "" : ""; // pause : play

    void UpdatePlayer(double recorded)
    {
        var total = Math.Max(recorded, _playerOpen && _player.NaturalDuration.HasTimeSpan ? _player.NaturalDuration.TimeSpan.TotalSeconds : 0);
        var pos = _playerOpen ? _player.Position.TotalSeconds : _pendingSeek ?? Seek.Value;
        _seeking = true;
        Seek.Maximum = Math.Max(1, total);
        Seek.Value = Math.Clamp(pos, 0, Seek.Maximum);
        _seeking = false;
        PlayTime.Text = _preparing ? "PREPARING…" : $"{Length(pos)} / {Length(total)}";
        PlayButton.IsEnabled = !_preparing && _session != null && File.Exists(_session.AudioPath);
        PlayButton.ToolTip = _prepared is { GainDb: > 0.5 } p ? $"Play from the cursor (level brought up {p.GainDb:0} dB)" : "Play from the cursor";
    }

    void Seek_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_seeking) return;
        if (_playerOpen) _player.Position = TimeSpan.FromSeconds(e.NewValue);
        else _pendingSeek = e.NewValue;
    }

    void ClosePlayer()
    {
        _skipTick.Stop();
        _player.Stop();
        _player.Close();
        _playing = _playerOpen = _autoPlay = _prepareFailed = false;
        _prepared = null;
        _pendingSeek = null;
        if (IsInitialized) ShowPlay();
    }

    // ----- right-click: jump to this moment in the recording -----

    void AttachJump(TextBox box, NoteDoc doc)
    {
        var jump = new MenuItem();
        jump.Click += (_, _) => { if (jump.Tag is double at) PlayFrom(at); };
        var menu = new ContextMenu();
        menu.Items.Add(jump);
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Command = ApplicationCommands.Cut });
        menu.Items.Add(new MenuItem { Command = ApplicationCommands.Copy });
        menu.Items.Add(new MenuItem { Command = ApplicationCommands.Paste });
        box.ContextMenu = menu;
        box.ContextMenuOpening += (_, e) =>
        {
            // The cursor goes where the right-click was, unless that was inside the selection.
            if (e.CursorLeft >= 0)
            {
                var at = box.GetCharacterIndexFromPoint(Mouse.GetPosition(box), true);
                if (at >= 0 && (box.SelectionLength == 0 || at < box.SelectionStart || at > box.SelectionStart + box.SelectionLength)) box.CaretIndex = at;
            }
            var seconds = doc == NoteDoc.Summary ? SummaryMoment(box) : _session?.SecondsAt(doc, box.CaretIndex);
            ShowJump(jump, seconds);
        };
    }

    void AttachJumpEdited()
    {
        var jump = new MenuItem();
        jump.Click += (_, _) => { if (jump.Tag is double at) PlayFrom(at); };
        var menu = new ContextMenu();
        menu.Items.Add(jump);
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Command = ApplicationCommands.Copy });
        EditedBox.ContextMenu = menu;
        EditedBox.ContextMenuOpening += (_, e) =>
        {
            var pointer = e.CursorLeft >= 0 ? EditedBox.GetPositionFromPoint(Mouse.GetPosition(EditedBox), true) : EditedBox.CaretPosition;
            var run = pointer?.Parent as Run
                ?? pointer?.GetAdjacentElement(LogicalDirection.Backward) as Run
                ?? pointer?.GetAdjacentElement(LogicalDirection.Forward) as Run;
            ShowJump(jump, run?.Tag as double?);
        };
    }

    void ShowJump(MenuItem jump, double? seconds)
    {
        jump.Tag = seconds;
        jump.IsEnabled = seconds != null && _session != null && !Live && File.Exists(_session.AudioPath);
        jump.Header = Live ? "Jump to this moment in the recording (once the session has stopped)"
            : seconds is { } at ? $"Jump to this moment in the recording  ·  {Length(at)}"
            : "Jump to this moment in the recording";
    }

    /// <summary>The summary doesn't follow the recording in order, so a sentence in it leads to the section whose own
    /// summary shares the most words with it.</summary>
    double? SummaryMoment(TextBox box)
    {
        if (_session == null || box.Text.Length == 0) return null;
        var sections = _session.Digests.Where(d => d.Level == 0).ToList();
        if (sections.Count == 0) return null;
        var text = box.Text;
        var caret = Math.Clamp(box.CaretIndex, 0, text.Length);
        var ends = new[] { '\n', '.', '!', '?' };
        var start = text.LastIndexOfAny(ends, Math.Max(0, caret - 1)) + 1;
        var end = caret < text.Length ? text.IndexOfAny(ends, caret) : -1;
        var words = Keywords(text[start..(end < 0 ? text.Length : end)]);
        if (words.Count == 0) return null;
        NoteDigest? best = null;
        var bestScore = 0;
        foreach (var d in sections)
        {
            var score = Keywords(d.Text).Count(words.Contains);
            if (score > bestScore) { bestScore = score; best = d; }
        }
        return best?.Start;
    }

    static HashSet<string> Keywords(string s) => new(s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
        .Select(w => w.Trim('.', ',', ';', ':', '!', '?', '"', '\'', '(', ')', '-', '–').ToLowerInvariant())
        .Where(w => w.Length >= 4));
}
