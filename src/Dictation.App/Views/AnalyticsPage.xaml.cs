using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Dictation.Core.Notes;
using Dictation.Core.Session;

namespace Dictation.App.Views;

/// <summary>
/// Analytics: how dictation goes over a period (7, 30 or 90 days, or everything). Readouts and charts come from the
/// daily counts (usage.json); words, phrases, corrections, fillers, hours and profiles from the word tally (words.json),
/// which keeps counts only. Drawn like the dashboard: cells sharing hairline edges, ink with one accent.
/// </summary>
public partial class AnalyticsPage : UserControl
{
    /// <summary>Typing speed that "time saved" is measured against (changed by clicking it).</summary>
    static double TypingWpm => Math.Max(1, App.Services.Settings.Current.TypingWpm);

    int? _days = 30;
    /// <summary>The app or site whose words are shown (<see cref="WordTally.AppKey"/>), or null for every app; the page
    /// always opens on every app.</summary>
    string? _app;
    string _appLabel = "";

    public AnalyticsPage()
    {
        InitializeComponent();
        // Live: every dictation (word tally, daily counts) and every reading (daily counts) redraws the page.
        Loaded += (_, _) =>
        {
            App.Services.Words.Changed += OnDataChanged;
            App.Services.Usage.Changed += OnDataChanged;
            App.Services.NotesStore.Sessions.CollectionChanged += OnSessionsChanged;
            _app = null;
            Build();
        };
        Unloaded += (_, _) =>
        {
            App.Services.Words.Changed -= OnDataChanged;
            App.Services.Usage.Changed -= OnDataChanged;
            App.Services.NotesStore.Sessions.CollectionChanged -= OnSessionsChanged;
        };
    }

    void OnSessionsChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e) => OnDataChanged();

    bool _rebuildQueued;

    /// <summary>The stores changed (the word tally on a background thread): redraw once, on the UI thread, however
    /// many changes arrive together (a dictation updates both stores).</summary>
    void OnDataChanged()
    {
        if (_rebuildQueued) return;
        _rebuildQueued = true;
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
        {
            _rebuildQueued = false;
            if (IsLoaded) Build();
        });
    }

    FontFamily Mono => (FontFamily)FindResource("Ob.Mono");

    void Build()
    {
        BuildPeriods();
        Body.Children.Clear();
        var sv = App.Services;
        var today = DateTime.Today;
        var from = _days is { } n ? today.AddDays(1 - n) : (DateTime?)null;
        var usage = sv.Usage.InPeriod(today, _days);
        var tally = sv.Words.Days(from);
        var tallyOn = sv.Settings.Current.KeepWordTally;

        Summary.Text = (_days switch { 7 => "Last 7 days", 30 => "Last 30 days", 90 => "Last 90 days", _ => "Everything so far" }) +
                       ": how you dictate, what gets corrected, and the words you reach for.";
        TallyNote.Text = tallyOn ? "WORD TALLY // ON // COUNTS ONLY, NEVER SENTENCES" : "WORD TALLY // OFF // TURN IT ON UNDER SETTINGS › HISTORY";

        Body.Children.Add(Readouts(usage, today));
        // Output by app, and the words of the app (or site) picked there: every app unless one is.
        Body.Children.Add(Row(new[] { 1.0 }, Apps(usage)));
        var shown = _app == null ? tally : WordTally.ForApp(tally, _app);
        Body.Children.Add(Row(new[] { 1.0, 1.0, 1.0 },
            Corrections(shown, tallyOn), TopWords(shown, tallyOn), Phrases(shown, tallyOn)));
        Body.Children.Add(Row(new[] { 1.4, 1.0 }, WordsPerDay(usage, today), Heatmap(shown, tallyOn)));
        Body.Children.Add(Row(new[] { 1.0 }, Profiles(tally, tallyOn)));
        AddNotes(today);
    }

    // ===== period selector =====

    void BuildPeriods()
    {
        Periods.Children.Clear();
        foreach (var (label, days) in new (string, int?)[] { ("7D", 7), ("30D", 30), ("90D", 90), ("ALL", null) })
        {
            var on = days == _days;
            var b = new Button
            {
                Content = label, MinWidth = 52, Margin = new Thickness(4, 0, 0, 0),
                Style = (Style)FindResource(on ? "PrimaryButton" : "QuietButton"),
                ToolTip = days is { } d ? $"The last {d} days" : "Everything so far",
            };
            System.Windows.Automation.AutomationProperties.SetName(b, (string)b.ToolTip);
            b.Click += (_, _) => { _days = days; Build(); };
            Periods.Children.Add(b);
        }
    }

    // ===== 01 readouts =====

    FrameworkElement Readouts(IReadOnlyList<UsageDay> usage, DateTime today)
    {
        var words = usage.Sum(d => d.Words);
        var dictations = usage.Sum(d => d.Dictations);
        var seconds = usage.Sum(d => d.SpeakingSeconds);
        var finishN = usage.Sum(d => d.FinishCount);
        var finish = usage.Sum(d => d.FinishSeconds);
        var aiEdited = usage.Sum(d => d.AiEdited);
        var aiKept = usage.Sum(d => d.AiKept);
        double? pace = seconds >= 30 ? words / (seconds / 60) : null;

        string paceSub = "words per minute while talking";
        if (pace is { } p && _days is { } n)
        {
            var before = App.Services.Usage.InPeriod(today.AddDays(-n), n);
            var bs = before.Sum(d => d.SpeakingSeconds);
            if (bs >= 30)
            {
                var delta = p - before.Sum(d => d.Words) / (bs / 60);
                paceSub = $"{(delta >= 0 ? "+" : "−")}{Math.Abs(delta):0} vs the {n} days before";
            }
        }

        // How long the voice actually spoke (at the speed of each reading); counted from 5.10.0 on.
        var readSeconds = usage.Sum(d => d.SecondsRead);
        var timedWords = usage.Where(d => d.SecondsRead > 0).Sum(d => d.WordsRead);
        var readSub = readSeconds >= 30 ? $"real listening time · {timedWords / (readSeconds / 60):0} wpm" : readSeconds > 0 ? "real listening time" : "counted from 5.10.0 on";

        var saved = TimeSpan.FromMinutes(Math.Max(0, words / TypingWpm - (seconds + finish) / 60));
        var cells = new[]
        {
            Readout("WORDS DICTATED", words.ToString("N0"), $"in {dictations:N0} dictation{(dictations == 1 ? "" : "s")}", accent: true),
            Readout("SPEAKING PACE", pace is { } p2 ? $"{p2:0} wpm" : "—", paceSub),
            Readout("TIME SAVED", words == 0 ? "—" : saved.TotalHours >= 1 ? $"{saved.TotalHours:0.0} h" : $"{saved.TotalMinutes:0} min", TypingSpeed()),
            Readout("TURNAROUND", finishN > 0 ? $"{finish / finishN:0.0} s" : "—", "stop → text in place"),
            Readout("AI EDITS KEPT", aiEdited > 0 ? $"{aiKept / (double)aiEdited:P0}" : "—",
                aiEdited > 0 ? $"safety net rejected {(aiEdited - aiKept) / (double)aiEdited:P0}" : "no AI edits yet"),
            Readout("READ ALOUD", $"{usage.Sum(d => d.WordsRead):N0} w", $"in {usage.Sum(d => d.Readings):N0} readings"),
            Readout("TIME READ ALOUD", readSeconds > 0 ? Duration(readSeconds) : "—", readSub),
        };
        var grid = new UniformGrid { Columns = cells.Length, Rows = 1 };
        foreach (var c in cells) grid.Children.Add(c);
        return Framed(grid, top: 0);
    }

    FrameworkElement Readout(string label, string value, string sub, bool accent = false) => Readout(label, value, Muted(sub, 11), accent);

    /// <summary>"vs typing at 40 wpm" under TIME SAVED: a click turns the number into a box to type another speed.</summary>
    FrameworkElement TypingSpeed()
    {
        var host = new ContentControl();
        void ShowText()
        {
            var t = Muted($"vs typing at {TypingWpm:0} wpm ✎", 11);
            t.Cursor = Cursors.Hand;
            t.TextDecorations = TextDecorations.Underline;
            t.ToolTip = "Click to change the typing speed time saved is measured against";
            t.MouseLeftButtonUp += (_, e) => { e.Handled = true; ShowEditor(); };
            host.Content = t;
        }
        void ShowEditor()
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            var before = Muted("vs typing at ", 11);
            before.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(before);
            var box = new TextBox { Text = TypingWpm.ToString("0"), Width = 52, Height = 24, MinHeight = 0, FontSize = 11, Padding = new Thickness(4, 1, 4, 1),
                VerticalContentAlignment = VerticalAlignment.Center };
            System.Windows.Automation.AutomationProperties.SetName(box, "Typing speed, words per minute");
            row.Children.Add(box);
            var after = Muted(" wpm", 11);
            after.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(after);
            host.Content = row;
            var done = false;
            void Commit(bool keep)
            {
                if (done) return;
                done = true;
                if (keep && int.TryParse(box.Text.Trim(), out var wpm) && wpm is >= 5 and <= 300 && wpm != App.Services.Settings.Current.TypingWpm)
                {
                    App.Services.Settings.Current.TypingWpm = wpm;
                    App.Services.Settings.Save();
                    Build();
                }
                else ShowText();
            }
            box.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter) { e.Handled = true; Commit(true); }
                else if (e.Key == Key.Escape) { e.Handled = true; Commit(false); }
            };
            box.LostKeyboardFocus += (_, _) => Commit(true);
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () => { box.Focus(); box.SelectAll(); });
        }
        ShowText();
        return host;
    }

    FrameworkElement Readout(string label, string value, FrameworkElement sub, bool accent = false)
    {
        var s = new StackPanel();
        s.Children.Add(new TextBlock { Text = label, Style = (Style)FindResource("MonoLabel"), TextTrimming = TextTrimming.CharacterEllipsis });
        var v = new TextBlock { Text = value, FontFamily = Mono, FontSize = 24, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 6, 0, 2),
            TextTrimming = TextTrimming.CharacterEllipsis };
        v.SetResourceReference(TextBlock.ForegroundProperty, accent ? "Ob.Accent" : "Ob.Text");
        s.Children.Add(v);
        s.Children.Add(sub);
        return Cell(s);
    }

    // ===== 03 most corrected, 04 most used words, 05 phrases and fillers (of the app picked in 02) =====

    /// <summary>A section's right-hand label: its own, or which app or site it is showing.</summary>
    string Scope(string own) => _app == null ? own : "IN " + _appLabel.ToUpper();

    /// <summary>An empty section's text: its own, or why the app picked has nothing yet.</summary>
    string Hint(string own) => _app == null ? own
        : $"Nothing counted for {_appLabel} in this period yet. Words are counted per app from 5.10.0 on, and from the dictations History still had then.";

    FrameworkElement Corrections(IReadOnlyList<TallyDay> tally, bool on)
    {
        var s = new StackPanel();
        s.Children.Add(Head("03 // MOST CORRECTED", Scope("HEARD → WRITTEN")));
        var intro = Muted("Words the AI fixes again and again. Add one to the speech vocabulary and the recognizer hears it right next time.", 11.5);
        intro.Margin = new Thickness(0, 0, 0, 8);
        s.Children.Add(intro);
        var top = WordTally.Top(tally, d => d.Corrections, 8);
        if (!on || top.Count == 0) { s.Children.Add(Empty(on, Hint("Corrections show up here once the AI has fixed the same words a few times."))); return Cell(s); }
        foreach (var (key, n) in top)
        {
            var parts = key.Split(WordTally.Arrow);
            if (parts.Length != 2) continue;
            var (heard, written) = (parts[0], parts[1]);
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 0) };
            var button = new Button { Style = (Style)FindResource("QuietButton"), FontSize = 10, Padding = new Thickness(10, 3, 10, 3),
                Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            void ShowState()
            {
                var added = InVocabulary(written);
                button.Content = added ? "ADDED ✓" : "ADD TO VOCABULARY";
                button.IsEnabled = !added;
                button.ToolTip = added ? $"\"{written}\" is in the speech vocabulary (Settings › Speech recognition)"
                    : $"Add \"{written}\" to the speech vocabulary, so the recognizer expects it";
                System.Windows.Automation.AutomationProperties.SetName(button, (string)button.ToolTip);
            }
            ShowState();
            button.Click += (_, _) => { AddToVocabulary(written); ShowState(); };
            DockPanel.SetDock(button, Dock.Right);
            row.Children.Add(button);
            var count = new TextBlock { Text = $"×{n:N0}", FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
            count.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            DockPanel.SetDock(count, Dock.Right);
            row.Children.Add(count);
            var pair = new TextBlock { FontFamily = Mono, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            var h = new System.Windows.Documents.Run(heard) { TextDecorations = TextDecorations.Strikethrough };
            h.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "Ob.Muted");
            pair.Inlines.Add(h);
            pair.Inlines.Add(new System.Windows.Documents.Run("  →  "));
            var w = new System.Windows.Documents.Run(written) { FontWeight = FontWeights.Bold };
            w.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "Ob.Accent");
            pair.Inlines.Add(w);
            pair.ToolTip = $"Heard \"{heard}\", the AI wrote \"{written}\" ({n:N0} time{(n == 1 ? "" : "s")})";
            row.Children.Add(pair);
            s.Children.Add(Ruled(row));
        }
        return Cell(s);
    }

    /// <summary>The speech vocabulary is the recognizer's hint (Settings › Speech recognition): a comma-separated list
    /// of words it should expect. It is read at the start of every dictation, so an addition works right away.</summary>
    static bool InVocabulary(string word) =>
        Regex.IsMatch(App.Services.Settings.Current.Asr.VocabularyHint ?? "", @"(^|[\s,;])" + Regex.Escape(word) + @"($|[\s,;.])", RegexOptions.IgnoreCase);

    static void AddToVocabulary(string word)
    {
        if (InVocabulary(word)) return;
        var asr = App.Services.Settings.Current.Asr;
        var hint = (asr.VocabularyHint ?? "").Trim().TrimEnd(',', ';');
        asr.VocabularyHint = hint.Length == 0 ? word : hint + ", " + word;
        App.Services.Settings.Save();
    }

    FrameworkElement TopWords(IReadOnlyList<TallyDay> tally, bool on)
    {
        var s = new StackPanel();
        s.Children.Add(Head("04 // MOST USED WORDS", Scope("COMMON WORDS LEFT OUT")));
        var top = WordTally.Top(tally, d => d.Words, 10);
        if (!on || top.Count == 0) { s.Children.Add(Empty(on, Hint("Your most used words appear here after a few dictations."))); return Cell(s); }
        var max = top[0].Count;
        for (var i = 0; i < top.Count; i++)
        {
            var (word, n) = top[i];
            var g = new Grid { Height = 24 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.6, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
            var rank = new TextBlock { Text = (i + 1).ToString("00"), FontFamily = Mono, FontSize = 10, VerticalAlignment = VerticalAlignment.Center };
            rank.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            g.Children.Add(rank);
            var name = new TextBlock { Text = word, FontFamily = Mono, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 8, 0), ToolTip = word };
            Grid.SetColumn(name, 1);
            g.Children.Add(name);
            g.Children.Add(Meter(n / (double)max, i == 0, 2));
            var count = new TextBlock { Text = n.ToString("N0"), FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Right };
            Grid.SetColumn(count, 3);
            g.Children.Add(count);
            s.Children.Add(g);
        }
        return Cell(s);
    }

    /// <summary>A horizontal bar filled to <paramref name="fraction"/>, in the given grid column.</summary>
    static FrameworkElement Meter(double fraction, bool accent, int column)
    {
        var track = new Grid { Height = 8, VerticalAlignment = VerticalAlignment.Center };
        track.SetResourceReference(Panel.BackgroundProperty, "Ob.Subtle");
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.02, fraction), GridUnitType.Star) });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0, 1 - fraction), GridUnitType.Star) });
        var fill = new Border();
        fill.SetResourceReference(Border.BackgroundProperty, accent ? "Ob.Accent" : "Ob.Strong");
        track.Children.Add(fill);
        Grid.SetColumn(track, column);
        return track;
    }

    FrameworkElement Phrases(IReadOnlyList<TallyDay> tally, bool on)
    {
        var s = new StackPanel();
        s.Children.Add(Head("05 // COMMON PHRASES", Scope("3 TO 4 WORDS")));
        var top = WordTally.TopPhrases(tally, 8);
        if (!on || top.Count == 0) s.Children.Add(Empty(on, Hint("Phrases you say again and again appear here.")));
        else
            foreach (var (phrase, n) in top)
            {
                var row = new DockPanel();
                var count = new TextBlock { Text = $"×{n:N0}", FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
                count.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
                DockPanel.SetDock(count, Dock.Right);
                row.Children.Add(count);
                row.Children.Add(new TextBlock { Text = $"“{phrase}”", FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = phrase });
                s.Children.Add(Ruled(row));
            }

        // Fillers removed, with the change on the period before
        var fillers = WordTally.Top(tally, d => d.Fillers, 6);
        var total = fillers.Sum(f => f.Count);
        var head = new DockPanel { Margin = new Thickness(0, 14, 0, 0) };
        var big = new TextBlock { Text = on ? total.ToString("N0") : "—", FontFamily = Mono, FontSize = 16, FontWeight = FontWeights.Bold };
        DockPanel.SetDock(big, Dock.Right);
        head.Children.Add(big);
        head.Children.Add(new TextBlock { Text = "FILLERS REMOVED", FontFamily = Mono, FontSize = 11, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center });
        var frame = new Border { BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(0, 8, 0, 0), Margin = new Thickness(0, 10, 0, 0), Child = head };
        frame.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
        head.Margin = new Thickness(0);
        s.Children.Add(frame);
        var detail = total == 0 ? "None taken out yet." : string.Join(" · ", fillers.Select(f => $"{f.Key} {f.Count:N0}"));
        if (on && total > 0 && _days is { } n2)
        {
            IEnumerable<TallyDay> before = App.Services.Words.Days(DateTime.Today.AddDays(1 - 2 * n2)).Where(d => d.Day < DateTime.Today.AddDays(1 - n2));
            if (_app != null) before = WordTally.ForApp(before, _app);
            var prev = before.Sum(d => d.Fillers.Values.Sum());
            if (prev > 0) detail += $". {(total <= prev ? "Down" : "Up")} {Math.Abs(total - prev) / (double)prev:P0} on the {n2} days before.";
        }
        s.Children.Add(Muted(on ? detail : "", 11));
        return Cell(s);
    }

    // ===== 06 words per day, 07 when you dictate =====

    FrameworkElement WordsPerDay(IReadOnlyList<UsageDay> usage, DateTime today)
    {
        var s = new DockPanel();
        // Days for a week or a month, weeks for 90 days, months for everything.
        var buckets = new List<(string Tick, DateTime From, DateTime To)>();
        if (_days is 7 or 30)
            for (var i = _days.Value - 1; i >= 0; i--) { var d = today.AddDays(-i); buckets.Add((i == 0 ? "NOW" : _days == 7 || d.Day % 5 == 0 ? (_days == 7 ? d.ToString("ddd")[..2].ToUpper() : d.Day.ToString()) : "", d, d)); }
        else if (_days == 90)
            for (var i = 12; i >= 0; i--) { var to = today.AddDays(-7 * i); buckets.Add((i == 0 ? "NOW" : i % 2 == 0 ? to.ToString("d MMM").ToUpper() : "", to.AddDays(-6), to)); }
        else
        {
            var first = usage.Count > 0 ? usage.Min(d => d.Day) : today;
            var m = new DateTime(first.Year, first.Month, 1);
            if ((today.Year - m.Year) * 12 + today.Month - m.Month > 23) m = new DateTime(today.Year, today.Month, 1).AddMonths(-23);
            for (; m <= today; m = m.AddMonths(1)) buckets.Add((m.ToString("MMM").ToUpper(), m, m.AddMonths(1).AddDays(-1)));
            buckets[^1] = ("NOW", buckets[^1].From, buckets[^1].To);
        }
        var unit = _days is 7 or 30 ? "DAY" : _days == 90 ? "WEEK" : "MONTH";
        var head = Head($"06 // WORDS PER {unit}", "");
        var key = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        void Key(double opacity, string label)
        {
            var sw = new Border { Width = 9, Height = 9, Opacity = opacity, Margin = new Thickness(12, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
            sw.SetResourceReference(Border.BackgroundProperty, "Ob.Strong");
            key.Children.Add(sw);
            key.Children.Add(new TextBlock { Text = label, Style = (Style)FindResource("MonoLabel"), VerticalAlignment = VerticalAlignment.Center });
        }
        Key(1, "DICTATED");
        Key(0.3, "READ ALOUD");
        ((DockPanel)head).Children.Insert(0, key);
        DockPanel.SetDock(key, Dock.Right);
        DockPanel.SetDock(head, Dock.Top);
        s.Children.Add(head);

        var totals = buckets.Select(b => (b.Tick,
            Dictated: usage.Where(d => d.Day >= b.From && d.Day <= b.To).Sum(d => d.Words),
            Read: usage.Where(d => d.Day >= b.From && d.Day <= b.To).Sum(d => d.WordsRead))).ToList();
        if (totals.All(t => t.Dictated + t.Read == 0)) { s.Children.Add(Empty(true, "Dictate or read something aloud and your words appear here.")); return Cell(s, height: 230); }
        var max = Math.Max(1, totals.Max(t => Math.Max(t.Dictated, t.Read)));
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < totals.Count; i++)
        {
            var t = totals[i];
            var last = i == totals.Count - 1;
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            var pair = new Grid { Background = Brushes.Transparent, Margin = new Thickness(1, 0, 1, 0),
                ToolTip = $"{buckets[i].From:d MMM}{(buckets[i].From == buckets[i].To ? "" : $" – {buckets[i].To:d MMM}")}\n{t.Dictated:N0} words dictated\n{t.Read:N0} words read aloud" };
            pair.ColumnDefinitions.Add(new ColumnDefinition());
            pair.ColumnDefinitions.Add(new ColumnDefinition());
            pair.Children.Add(Bar(t.Dictated, max, last ? "Ob.Accent" : "Ob.Strong", 1, 0));
            pair.Children.Add(Bar(t.Read, max, "Ob.Strong", 0.3, 1));
            Grid.SetColumn(pair, i);
            grid.Children.Add(pair);
            var tick = new TextBlock { Text = t.Tick, FontFamily = Mono, FontSize = 9, HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 4, 0, 0), FontWeight = last ? FontWeights.Bold : FontWeights.Normal };
            tick.SetResourceReference(TextBlock.ForegroundProperty, last ? "Ob.Accent" : "Ob.Muted");
            Grid.SetColumn(tick, i);
            Grid.SetRow(tick, 2);
            grid.Children.Add(tick);
        }
        var baseline = new Border();
        baseline.SetResourceReference(Border.BackgroundProperty, "Ob.Divider");
        Grid.SetRow(baseline, 1);
        Grid.SetColumnSpan(baseline, totals.Count);
        grid.Children.Add(baseline);
        s.Children.Add(grid);
        return Cell(s, height: 230);
    }

    static FrameworkElement Bar(int value, int max, string resource, double opacity, int column)
    {
        var f = max > 0 ? value / (double)max : 0;
        var cell = new Grid { Margin = new Thickness(1, 0, 1, 0) };
        cell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1 - f, GridUnitType.Star) });
        cell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(f, GridUnitType.Star) });
        var bar = new Border { MinHeight = value > 0 ? 2 : 0, Opacity = opacity };
        bar.SetResourceReference(Border.BackgroundProperty, resource);
        Grid.SetRow(bar, 1);
        cell.Children.Add(bar);
        Grid.SetColumn(cell, column);
        return cell;
    }

    FrameworkElement Heatmap(IReadOnlyList<TallyDay> tally, bool on)
    {
        var s = new DockPanel();
        var head = Head("07 // WHEN YOU DICTATE", Scope("WEEKDAY × HOUR"));
        DockPanel.SetDock(head, Dock.Top);
        s.Children.Add(head);
        var week = WordTally.WeekHours(tally);
        var total = 0;
        foreach (var v in week) total += v;
        if (!on || total == 0) { s.Children.Add(Empty(on, Hint("Once you have dictated for a while, your busiest hours show here."))); return Cell(s, height: 230); }

        // Two-hour blocks: twelve columns read better than twenty-four.
        var blocks = new int[7, 12];
        var max = 1;
        for (var r = 0; r < 7; r++)
            for (var c = 0; c < 12; c++) { blocks[r, c] = week[r, 2 * c] + week[r, 2 * c + 1]; max = Math.Max(max, blocks[r, c]); }
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        for (var c = 0; c < 12; c++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        var names = new[] { "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN" };
        for (var r = 0; r < 8; r++) grid.RowDefinitions.Add(new RowDefinition { Height = r < 7 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        for (var r = 0; r < 7; r++)
        {
            var label = new TextBlock { Text = names[r], FontFamily = Mono, FontSize = 10, VerticalAlignment = VerticalAlignment.Center };
            label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            Grid.SetRow(label, r);
            grid.Children.Add(label);
            for (var c = 0; c < 12; c++)
            {
                var v = blocks[r, c];
                var cell = new Border { Margin = new Thickness(1.5), MinHeight = 14, BorderThickness = new Thickness(v > 0 ? 0 : 1),
                    ToolTip = $"{names[r]} {2 * c:00}:00–{2 * c + 2:00}:00 · {v:N0} dictation{(v == 1 ? "" : "s")}" };
                if (v > 0)
                {
                    cell.SetResourceReference(Border.BackgroundProperty, "Ob.Strong");
                    cell.Opacity = 0.15 + 0.85 * v / max;
                }
                else cell.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c + 1);
                grid.Children.Add(cell);
            }
        }
        for (var c = 0; c < 12; c += 2)
        {
            var hour = new TextBlock { Text = (2 * c).ToString(), FontFamily = Mono, FontSize = 9.5, Margin = new Thickness(2, 4, 0, 0) };
            hour.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            Grid.SetRow(hour, 7);
            Grid.SetColumn(hour, c + 1);
            grid.Children.Add(hour);
        }
        s.Children.Add(grid);
        return Cell(s, height: 230);
    }

    // ===== 08 profiles, 02 apps =====

    FrameworkElement Profiles(IReadOnlyList<TallyDay> tally, bool on)
    {
        var s = new StackPanel();
        s.Children.Add(Head("08 // HOW EACH PROFILE EDITS", "EVERY APP"));
        var rows = WordTally.ByProfile(tally);
        if (!on || rows.Count == 0) { s.Children.Add(Empty(on, "Each profile's edits are summed up here after you dictate with it.")); return Cell(s); }
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
        for (var i = 0; i < 4; i++) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        void Put(int row, int col, string text, bool header = false)
        {
            var t = new TextBlock { Text = text, FontFamily = Mono, FontSize = header ? 10 : 12, Margin = new Thickness(0, 5, 0, 5),
                HorizontalAlignment = col == 0 ? HorizontalAlignment.Left : HorizontalAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis };
            if (header) t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            Grid.SetRow(t, row);
            Grid.SetColumn(t, col);
            g.Children.Add(t);
        }
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        string[] heads = { "PROFILE", "USED", "WORDS CHANGED", "KEPT", "TURNAROUND" };
        for (var c = 0; c < heads.Length; c++) Put(0, c, heads[c], header: true);
        var r = 1;
        foreach (var (name, p) in rows.Take(8))
        {
            g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var line = new Border { BorderThickness = new Thickness(0, 1, 0, 0) };
            line.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
            Grid.SetRow(line, r);
            Grid.SetColumnSpan(line, 5);
            g.Children.Add(line);
            Put(r, 0, name);
            Put(r, 1, p.Dictations.ToString("N0"));
            Put(r, 2, p.AiEdited == 0 ? "—" : p.WordsHeard > 0 ? $"{Math.Min(1, p.WordsChanged / (double)p.WordsHeard):P0}" : "—");
            Put(r, 3, p.AiEdited == 0 ? "—" : $"{p.AiKept / (double)p.AiEdited:P0}");
            Put(r, 4, p.FinishCount > 0 ? $"{p.FinishSeconds / p.FinishCount:0.0} s" : "—");
            r++;
        }
        s.Children.Add(g);
        return Cell(s);
    }

    FrameworkElement Apps(IReadOnlyList<UsageDay> usage)
    {
        var s = new StackPanel();
        s.Children.Add(Head("02 // OUTPUT BY APP", "CLICK AN APP OR SITE: THE WORDS BELOW FOLLOW IT"));
        var apps = usage.SelectMany(d => d.Apps).GroupBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)
            .Select(g => (App: g.Key, Count: g.Sum(kv => kv.Value))).OrderByDescending(x => x.Count).ThenBy(x => x.App).Take(6).ToList();
        if (apps.Count == 0) { s.Children.Add(Empty(true, "The apps you dictate into appear here.")); return Cell(s); }
        const int blocks = 30;
        var total = Math.Max(1, usage.Sum(d => d.Dictations));
        s.Children.Add(AppRow("ALL APPS", "Every app", total, total, blocks, false, null, ""));
        foreach (var (app, count) in apps)
        {
            s.Children.Add(AppRow(app.ToUpper(), app, count, total, blocks, false, WordTally.AppKey(app), app));
            // A browser: its sites under it (the top four, the rest together), each with its own bar.
            var sites = UsageStore.SitesOf(usage, app);
            if (sites.Count == 0) continue;
            var shown = sites.Take(4).ToList();
            var rest = sites.Skip(4).Sum(x => x.Count) + Math.Max(0, count - sites.Sum(x => x.Count));
            foreach (var (site, n) in shown)
                s.Children.Add(AppRow("↳ " + site.ToUpper(), $"{site} in {app}", n, total, blocks, true, WordTally.AppKey(app, site), $"{site} in {app}"));
            if (rest > 0 && shown.Count > 0)
                s.Children.Add(AppRow("↳ OTHER", sites.Count > 4 ? $"Other sites in {app}" : $"{app}, from before sites were counted", rest, total, blocks, true,
                    null, null));
        }
        return Cell(s);
    }

    /// <summary>One row of Output by app: the name, a bar of blocks, and the count. A site row is indented, its bar lighter.
    /// A row with a <paramref name="label"/> can be clicked to show that app's (or site's) words below; ALL APPS
    /// (<paramref name="key"/> null, label "") shows everything. The row shown is in the accent.</summary>
    FrameworkElement AppRow(string text, string tip, int count, int max, int blocks, bool site, string? key, string? label)
    {
        var clickable = label != null;
        var selected = clickable && string.Equals(key, _app, StringComparison.OrdinalIgnoreCase);
        var g = new Grid { Height = site ? 22 : 26, Background = Brushes.Transparent };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.8, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2.4, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
        var name = new TextBlock { Text = (selected ? "▸ " : "") + text, FontFamily = Mono, FontSize = site ? 10 : 11, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(site ? 12 : 0, 0, 10, 0), ToolTip = tip,
            FontWeight = selected ? FontWeights.Bold : FontWeights.Normal };
        name.SetResourceReference(TextBlock.ForegroundProperty, selected ? "Ob.Accent" : site ? "Ob.Muted" : "Ob.Text");
        g.Children.Add(name);
        var filled = Math.Max(1, (int)Math.Round(count / (double)max * blocks));
        var track = new UniformGrid { Rows = 1, Columns = blocks, Height = site ? 7 : 10, VerticalAlignment = VerticalAlignment.Center,
            ToolTip = $"{tip}: {count:N0} dictation{(count == 1 ? "" : "s")}" };
        var fill = selected ? "Ob.Accent" : site ? "Ob.Muted" : "Ob.Strong";
        for (var b = 0; b < blocks; b++)
        {
            var block = new Border { BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 2, 0) };
            block.SetResourceReference(Border.BorderBrushProperty, b < filled ? fill : "Ob.Divider");
            if (b < filled) block.SetResourceReference(Border.BackgroundProperty, fill);
            track.Children.Add(block);
        }
        Grid.SetColumn(track, 1);
        g.Children.Add(track);
        var n = new TextBlock { Text = count.ToString("N0"), FontFamily = Mono, FontSize = site ? 10 : 11, VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right };
        n.SetResourceReference(TextBlock.ForegroundProperty, selected ? "Ob.Accent" : site ? "Ob.Muted" : "Ob.Text");
        Grid.SetColumn(n, 2);
        g.Children.Add(n);
        if (!clickable) return g;
        g.Cursor = Cursors.Hand;
        g.ToolTip = key == null ? "Show the words of every app" : $"Show the words dictated into {label}";
        g.MouseEnter += (_, _) => g.SetResourceReference(Panel.BackgroundProperty, "Ob.AccentWash");
        g.MouseLeave += (_, _) => g.Background = Brushes.Transparent;
        g.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            _app = key;
            _appLabel = label!;
            Build();
        };
        return g;
    }

    // ===== 09 to 11 Extended Notes =====

    void AddNotes(DateTime today)
    {
        var store = App.Services.NotesStore;
        var f = NotesStats.Compute(store.Sessions, _days is { } d ? today.AddDays(1 - d) : null);
        var ai = store.Usage.Totals(DateTime.Now, _days ?? 0);

        var title = new DockPanel { Margin = new Thickness(0, 26, 0, 0) };
        var note = new TextBlock { Text = "LECTURES AND MEETINGS // KEPT APART FROM DICTATION", Style = (Style)FindResource("MonoLabel"),
            VerticalAlignment = VerticalAlignment.Bottom };
        DockPanel.SetDock(note, Dock.Right);
        title.Children.Add(note);
        title.Children.Add(new TextBlock { Text = "09 // EXTENDED NOTES", FontFamily = Mono, FontSize = 13, FontWeight = FontWeights.Bold });
        Body.Children.Add(title);

        var longest = f.Longest.FirstOrDefault();
        var cells = new[]
        {
            Readout("SESSIONS", f.Sessions.ToString("N0"), f.Sessions > 0 ? $"{Duration(f.Seconds / f.Sessions)} each on average" : "none in this period", accent: true),
            Readout("TIME RECORDED", f.Seconds > 0 ? Duration(f.Seconds) : "—", longest != null ? $"longest {Duration(longest.Seconds)}" : "lectures, meetings, calls"),
            Readout("WORDS CAPTURED", f.WordsHeard.ToString("N0"), f.WordsPerMinute is { } w ? $"{w:0} a minute of recording" : "heard by the speech model"),
            Readout("YOUR OWN NOTES", $"{f.WordsTyped:N0} w", "typed in during sessions"),
            Readout("MARKERS", f.Markers.ToString("N0"), f.Markers > 0 && f.Seconds > 0 ? $"one every {Duration(f.Seconds / f.Markers)}" : "⚑ moments you marked"),
            Readout("FORMATTING KEPT", f.Steps > 0 ? $"{f.StepsKept / (double)f.Steps:P0}" : "—",
                $"{ai.AiRequests:N0} AI step{(ai.AiRequests == 1 ? "" : "s")}, formatting and summing up"),
        };
        var grid = new UniformGrid { Columns = cells.Length, Rows = 1 };
        foreach (var c in cells) grid.Children.Add(c);
        Body.Children.Add(Framed(grid, top: 8));
        Body.Children.Add(Row(new[] { 1.4, 1.0 }, LongestSessions(f), NotesSources(f)));
    }

    FrameworkElement LongestSessions(NotesFigures f)
    {
        var s = new StackPanel();
        s.Children.Add(Head("10 // LONGEST SESSIONS", "CLICK ONE TO OPEN IT"));
        if (f.Longest.Count == 0) { s.Children.Add(Muted("Your longest Extended Notes sessions appear here.", 12)); return Cell(s); }
        foreach (var n in f.Longest)
        {
            var row = new DockPanel { Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = $"Open \"{n.Title}\"" };
            var len = new TextBlock { Text = Duration(n.Seconds), FontFamily = Mono, FontSize = 12, FontWeight = FontWeights.Bold,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0), Width = 60, TextAlignment = TextAlignment.Right };
            DockPanel.SetDock(len, Dock.Right);
            row.Children.Add(len);
            var words = new TextBlock { Text = $"{NoteSession.Words(n.Transcript):N0} w", FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(10, 0, 0, 0) };
            words.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            DockPanel.SetDock(words, Dock.Right);
            row.Children.Add(words);
            var date = new TextBlock { Text = n.Started.ToString("d MMM").ToUpper(), FontFamily = Mono, FontSize = 10, Width = 56, VerticalAlignment = VerticalAlignment.Center };
            date.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            DockPanel.SetDock(date, Dock.Left);
            row.Children.Add(date);
            var name = new TextBlock { Text = n.Title, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(name);
            row.MouseEnter += (_, _) => name.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Accent");
            row.MouseLeave += (_, _) => name.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            var session = n;
            row.MouseLeftButtonUp += (_, e) => { e.Handled = true; (Window.GetWindow(this) as MainWindow)?.OpenNoteSession(session); };
            s.Children.Add(Ruled(row));
        }
        return Cell(s);
    }

    FrameworkElement NotesSources(NotesFigures f)
    {
        var s = new StackPanel();
        s.Children.Add(Head("11 // WHAT IT LISTENED TO", "BY TIME RECORDED"));
        if (f.Sessions == 0) { s.Children.Add(Muted("The microphone, the computer's audio, or both: how your sessions split shows here.", 12)); return Cell(s); }
        var max = Math.Max(1, f.Sources.Values.Max(v => v.Seconds));
        foreach (var (source, label) in new[] { (Dictation.Core.Notes.NotesSource.Mic, "MICROPHONE"), (Dictation.Core.Notes.NotesSource.Computer, "COMPUTER AUDIO"), (Dictation.Core.Notes.NotesSource.Both, "BOTH") })
        {
            var (n, sec) = f.Sources.GetValueOrDefault(source);
            var g = new Grid { Height = 28 };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.4, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
            g.Children.Add(new TextBlock { Text = label, FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
            g.Children.Add(Meter(sec / max, false, 1));
            var v = new TextBlock { Text = n == 0 ? "—" : $"{n:N0} · {Duration(sec)}", FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Right };
            Grid.SetColumn(v, 2);
            g.Children.Add(v);
            s.Children.Add(g);
        }
        return Cell(s);
    }

    /// <summary>A length of time the way a readout shows it: 45 s, 12 min, 1.4 h.</summary>
    static string Duration(double seconds) =>
        seconds < 60 ? $"{seconds:0} s" : seconds < 3600 ? $"{seconds / 60:0} min" : $"{seconds / 3600:0.0} h";

    // ===== pieces =====

    /// <summary>A row of cells sharing hairline edges, with the given column widths.</summary>
    FrameworkElement Row(double[] widths, params FrameworkElement[] cells)
    {
        var g = new Grid();
        for (var i = 0; i < cells.Length; i++)
        {
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(widths[i], GridUnitType.Star) });
            Grid.SetColumn(cells[i], i);
            g.Children.Add(cells[i]);
        }
        return Framed(g, top: 18);
    }

    /// <summary>The panel's top and left edges; each cell draws its right and bottom ones.</summary>
    static FrameworkElement Framed(UIElement content, double top)
    {
        var b = new Border { BorderThickness = new Thickness(1, 1, 0, 0), Margin = new Thickness(0, top, 0, 0), Child = content };
        b.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
        return b;
    }

    static Border Cell(UIElement content, double height = double.NaN)
    {
        var b = new Border { BorderThickness = new Thickness(0, 0, 1, 1), Padding = new Thickness(16, 12, 16, 14), Child = content, Height = height };
        b.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
        return b;
    }

    FrameworkElement Head(string title, string right)
    {
        var d = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        if (right.Length > 0)
        {
            var r = new TextBlock { Text = right, Style = (Style)FindResource("MonoLabel"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
            DockPanel.SetDock(r, Dock.Right);
            d.Children.Add(r);
        }
        d.Children.Add(new TextBlock { Text = title, FontFamily = Mono, FontSize = 11, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center });
        return d;
    }

    static TextBlock Muted(string text, double size)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        return t;
    }

    static TextBlock Empty(bool tallyOn, string text) =>
        Muted(tallyOn ? text : "The word tally is off. Turn it on under Settings › History to see this.", 12);

    /// <summary>A row with a hairline above it, as in a list.</summary>
    static Border Ruled(UIElement content)
    {
        var b = new Border { BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(0, 6, 0, 6), Child = content };
        b.SetResourceReference(Border.BorderBrushProperty, "Ob.Divider");
        return b;
    }
}
