using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;
using Dictation.Core.Setup;
using Dictation.Core.Speech;
using Dictation.Core.Text;
using Path = System.Windows.Shapes.Path;

namespace Dictation.App.Views;

/// <summary>
/// At a glance, without scrolling: what is active and loaded (tiles), how dictation is going (dials), and where the
/// words go (charts). Everything sizes to the window and refreshes every few seconds.
/// </summary>
public partial class DashboardPage : UserControl
{
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(3) };
    IReadOnlyList<string> _loadedAi = Array.Empty<string>();
    bool _refreshing;

    enum Dot { Ok, Busy, Off }

    public DashboardPage()
    {
        InitializeComponent();
        _timer.Tick += async (_, _) => await RefreshAsync();
        Loaded += async (_, _) => { _timer.Start(); await RefreshAsync(); };
        Unloaded += (_, _) => _timer.Stop();
        // The charts open History, where every dictation behind them is listed.
        foreach (var card in new[] { DaysCard, AppsCard })
        {
            card.Cursor = Cursors.Hand;
            card.MouseLeftButtonUp += (_, _) => TheApp.ShowPage("History");
        }
        Build();
    }

    /// <summary>The speech dial's number: free the speech model's memory right away.</summary>
    async void UnloadSpeechNow()
    {
        await App.UnloadNowAsync(speech: true, ai: false, voice: false);
        Build(); // the dial now reads "off"
    }

    /// <summary>Where each dial leads when clicked: the page that explains or changes what it shows.</summary>
    static string DialPage(string label) => label switch
    {
        "Dictated today" or "History" => "History",
        "Read aloud today" => "ReadAloud",
        "AI edits kept" => "SpeechToText", // the profiles, whose instructions and safety net decide what is kept
        "Turnaround" => "Models",
        "Speech model" => "Unloading",
        _ => "Dashboard",
    };

    async Task RefreshAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try { _loadedAi = await App.Services.Llm.LoadedModelsAsync(); }
        finally { _refreshing = false; }
        Build();
    }

    static App TheApp => (App)Application.Current;

    void Build()
    {
        var sv = App.Services;
        var s = sv.Settings.Current;
        var p = sv.Profiles.Active;
        var entries = sv.History.Entries.ToList();
        var now = DateTime.Now;
        var aiModel = string.IsNullOrWhiteSpace(p.Model) ? s.Llm.DefaultModel : p.Model!;
        var cloud = CloudModels.IsCloud(aiModel);
        var aiLoaded = _loadedAi.Any(n => n.StartsWith(aiModel, StringComparison.OrdinalIgnoreCase));
        var unload = s.UnloadAfterMinutes < 0 ? "right after each use" : s.UnloadAfterMinutes == 0 ? "never" : s.UnloadAfterMinutes >= 60 ? $"{s.UnloadAfterMinutes / 60.0:0.#} h" : $"{s.UnloadAfterMinutes} min";

        Clock.Text = $"{now:dddd d MMMM}, {now:t}";
        Summary.Text = sv.Controller.State != DictationState.Idle
            ? $"Dictating with {p.Name} right now."
            : $"Press {s.Hotkey} to dictate with {p.Name}. Select text and press {s.SpeakHotkey} to hear it.";
        Footer.Text = $"{AppInfo.Name} {AppInfo.VersionText}  ·  {sv.Usage.TotalWords:N0} words dictated in all  ·  " +
                      (s.Cloud.KeepOffline ? "Everything stays on this PC" : "Cloud AI allowed") +
                      $"  ·  {s.CycleProfileHotkey} switches profile  ·  models unload {(s.UnloadAfterMinutes < 0 ? unload : "after " + unload + " unused")}";

        // ----- tiles -----
        Tiles.Children.Clear();
        var traits = new List<string>();
        if (p.AutoProcess && p.RewriteWhole) traits.Add("rewrites whole");
        if (p.ShowPreview) traits.Add("previews");
        else if (s.TypeWhileSpeaking) traits.Add("types as you speak");
        if (p.ReadAloudAfterInsert) traits.Add("reads aloud");
        Tiles.Children.Add(Tile("PROFILE", p.Name,
            p.AutoProcess ? Dot.Ok : Dot.Off, p.AutoProcess ? (cloud ? "AI · cloud" : "AI · on this PC") : "No AI · raw words",
            traits.Count == 0 ? p.Description : string.Join(" · ", traits),
            () => ((MainWindow)Window.GetWindow(this)!).ShowProfile(p)));

        var dictating = sv.Controller.State != DictationState.Idle;
        var speechModel = SpeechModels.For(p, s.Asr);
        var speechLoaded = string.Equals(sv.Speech.LoadedModel, speechModel, StringComparison.OrdinalIgnoreCase);
        Tiles.Children.Add(Tile("SPEECH RECOGNITION", speechModel,
            dictating || speechLoaded ? Dot.Ok : Dot.Busy,
            dictating ? "Dictating…" : speechLoaded ? "Loaded" : "Not loaded · loads when you dictate",
            (s.Asr.Device == "auto" ? "GPU if available" : s.Asr.Device.ToUpperInvariant()) + " · " +
            (string.IsNullOrEmpty(s.Asr.Language) ? "any language" : s.Asr.Language),
            () => TheApp.ShowPage("Models")));

        Tiles.Children.Add(Tile("AI CLEANUP", p.AutoProcess ? aiModel : s.Llm.DefaultModel,
            cloud ? (s.Cloud.KeepOffline ? Dot.Busy : Dot.Ok) : aiLoaded ? Dot.Ok : Dot.Busy,
            cloud ? (s.Cloud.KeepOffline ? "Cloud · blocked by offline mode" : "Cloud · ready")
                  : aiLoaded ? "Loaded" : "Not loaded · loads when needed",
            _loadedAi.Count == 0 ? "Nothing in memory" : "In memory: " + string.Join(", ", _loadedAi),
            () => TheApp.ShowPage("Models")));

        var voiceId = App.VoiceFor(p);
        var windowsVoice = VoiceCatalog.IsWindowsVoice(voiceId);
        var installed = VoiceCatalog.IsInstalled(voiceId);
        Tiles.Children.Add(Tile("READ ALOUD", installed ? VoiceCatalog.ShortName(voiceId) : "Not installed",
            windowsVoice || sv.Tts.IsRunning ? Dot.Ok : installed ? Dot.Busy : Dot.Off,
            windowsVoice ? "Windows voice · ready" : sv.Tts.IsRunning ? "Voice loaded" : installed ? "Starts when you read" : "Downloads on first use",
            $"{VoiceCatalog.Model(VoiceCatalog.ModelOf(voiceId)).Name} · {s.TtsBaseSpeed:0.0#}× · {s.SpeakHotkey}",
            () => TheApp.ShowPage("ReadAloud")));

        // ----- dials -----
        Dials.Children.Clear();
        // Figures come from the daily counts (UsageStore), which survive History being trimmed, cleared or off.
        var usage = sv.Usage;
        var days = usage.PerDay(now);
        var today = days[^1].Words;
        var best = days.Max(d => d.Words);
        Dials.Children.Add(Dial(best > 0 ? today / (double)best : 0, today.ToString("N0"), "Dictated today",
            best > 0 ? $"words · best day {best:N0}" : "no dictation yet"));
        var readToday = days[^1].WordsRead;
        var bestRead = days.Max(d => d.WordsRead);
        Dials.Children.Add(Dial(bestRead > 0 ? readToday / (double)bestRead : 0, readToday.ToString("N0"), "Read aloud today",
            bestRead > 0 ? $"words · best day {bestRead:N0}" : "nothing read yet"));

        var finish = usage.AverageFinishSeconds(now);
        Dials.Children.Add(Dial(finish is { } f ? Math.Clamp(f / 10.0, 0, 1) : 0, finish is { } f2 ? $"{f2:0.0} s" : "—",
            "Turnaround", "stop → text in place, 7 days"));

        var kept = usage.AiKeptShare(now);
        Dials.Children.Add(Dial(kept ?? 0, kept is { } k ? $"{k:P0}" : "—", "AI edits kept", "last 30 days"));

        Dials.Children.Add(Dial(s.HistoryLimit > 0 ? entries.Count / (double)s.HistoryLimit : entries.Count > 0 ? 1 : 0,
            entries.Count.ToString(), "History", s.HistoryLimit > 0 ? $"of {s.HistoryLimit} kept" : "all kept, no limit"));

        if (dictating) Dials.Children.Add(Dial(1, "busy", "Speech model", "dictating now"));
        else if (!sv.Speech.IsReady) Dials.Children.Add(Dial(0, "off", "Speech model", "loads when you dictate"));
        else if (s.UnloadAfterMinutes <= 0)
            Dials.Children.Add(Dial(1, "on", "Speech model", s.UnloadAfterMinutes < 0 ? "unloads right after use" : "stays loaded",
                UnloadSpeechNow, "Click to unload the speech model now"));
        else
        {
            var limit = TimeSpan.FromMinutes(s.UnloadAfterMinutes);
            var left = limit - (now - sv.Controller.LastActivity);
            if (left < TimeSpan.Zero) left = TimeSpan.Zero;
            Dials.Children.Add(Dial(left / limit, left.TotalMinutes >= 1 ? $"{Math.Ceiling(left.TotalMinutes):0} min" : "<1 min",
                "Speech model", "until it unloads", UnloadSpeechNow, "Click to unload the speech model now"));
        }

        // ----- charts -----
        DaysCard.Child = DaysChart(days, usage.Streak(now));
        AppsCard.Child = AppsChart(usage.TopApps(now));
    }

    // ===== pieces =====

    const double TileDesignWidth = 220;

    FrameworkElement Tile(string label, string title, Dot dot, string status, string detail, Action open)
    {
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = label, Style = (Style)FindResource("MonoLabel") });
        panel.Children.Add(new TextBlock
        {
            Text = title, FontSize = 16, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = title,
        });
        var line = new DockPanel { Margin = new Thickness(0, 5, 0, 0) };
        var light = new Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center };
        light.SetResourceReference(Shape.FillProperty, dot switch { Dot.Ok => "Ob.Ok", Dot.Busy => "Ob.Busy", _ => "Ob.Track" });
        DockPanel.SetDock(light, Dock.Left);
        line.Children.Add(light);
        line.Children.Add(new TextBlock { Text = status, FontSize = 12.5, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = status });
        panel.Children.Add(line);
        var sub = new TextBlock { Text = detail, FontSize = 12, Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = detail };
        sub.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        panel.Children.Add(sub);

        // Laid out at a fixed design width, then scaled to the tile: the text grows with the window instead of staying
        // small in a big tile (and still trims long names at that width).
        panel.Width = TileDesignWidth;
        var card = new Border
        {
            Style = (Style)FindResource("Card"), Margin = new Thickness(4), Padding = new Thickness(14, 10, 14, 10),
            Child = new Viewbox
            {
                Stretch = Stretch.Uniform, Child = panel,
                HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center,
            },
            Cursor = Cursors.Hand, ClipToBounds = true,
        };
        card.MouseLeftButtonUp += (_, _) => open();
        return card;
    }

    /// <summary>A 270° gauge, drawn at a fixed design size and scaled to its cell.</summary>
    /// <param name="valueClick">What clicking the big number does (instead of opening the dial's page), if anything.</param>
    FrameworkElement Dial(double fraction, string value, string label, string sub, Action? valueClick = null, string? valueTip = null)
    {
        const double size = 150, cx = 75, cy = 70, r = 54, thickness = 9;
        var canvas = new Grid { Width = size, Height = size };

        var track = Arc(cx, cy, r, 1);
        track.StrokeThickness = thickness;
        track.SetResourceReference(Shape.StrokeProperty, "Ob.Track");
        canvas.Children.Add(track);
        if (fraction > 0.002)
        {
            var arc = Arc(cx, cy, r, Math.Min(fraction, 0.9999));
            arc.StrokeThickness = thickness;
            arc.SetResourceReference(Shape.StrokeProperty, "Ob.Record");
            canvas.Children.Add(arc);
        }

        var center = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 44, 0, 0) };
        var big = new TextBlock { Text = value, FontSize = 24, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
        if (valueClick != null)
        {
            // The number is its own button; the rest of the dial still opens the page.
            big.Background = Brushes.Transparent;
            big.ToolTip = valueTip;
            big.MouseLeftButtonUp += (_, e) => { e.Handled = true; valueClick(); };
        }
        center.Children.Add(big);
        var name = new TextBlock { Text = label, FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 1, 0, 0) };
        name.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        center.Children.Add(name);
        canvas.Children.Add(center);

        var note = new TextBlock
        {
            Text = sub, FontSize = 10.5, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 4), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 140,
        };
        note.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        canvas.Children.Add(note);

        var card = new Border
        {
            Style = (Style)FindResource("Card"), Margin = new Thickness(4), Padding = new Thickness(6),
            Child = new Viewbox { Stretch = Stretch.Uniform, Child = canvas }, ToolTip = $"{label}: {value} ({sub})",
            Cursor = Cursors.Hand,
        };
        card.MouseLeftButtonUp += (_, _) => TheApp.ShowPage(DialPage(label));
        return card;
    }

    /// <summary>An arc of the gauge: from the lower left, clockwise, <paramref name="fraction"/> of 270°.</summary>
    static Path Arc(double cx, double cy, double r, double fraction)
    {
        const double start = 135, sweepAll = 270;
        var sweep = sweepAll * Math.Clamp(fraction, 0, 0.9999);
        Point At(double deg) => new(cx + r * Math.Cos(deg * Math.PI / 180), cy + r * Math.Sin(deg * Math.PI / 180));
        var figure = new PathFigure { StartPoint = At(start), IsClosed = false, IsFilled = false };
        figure.Segments.Add(new ArcSegment(At(start + sweep), new Size(r, r), 0, sweep > 180, SweepDirection.Clockwise, true));
        return new Path
        {
            Data = new PathGeometry(new[] { figure }),
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
    }

    FrameworkElement Header(string title, string right)
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var r = new TextBlock { Text = right, FontSize = 12 };
        r.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        DockPanel.SetDock(r, Dock.Right);
        header.Children.Add(r);
        header.Children.Add(new TextBlock { Text = title, Style = (Style)FindResource("MonoLabel") });
        return header;
    }

    TextBlock Empty(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        return t;
    }

    /// <summary>Words per day as columns; today in the accent colour. Hover a day for its numbers.</summary>
    FrameworkElement DaysChart(IReadOnlyList<DayTotal> days, int streak)
    {
        var root = new DockPanel();
        var dictated = days.Sum(d => d.Words);
        var read = days.Sum(d => d.WordsRead);
        var header = Header("WORDS PER DAY · LAST 14 DAYS", $"{dictated:N0} dictated · {read:N0} read aloud" +
                                                          (streak > 1 ? $" · {streak}-day streak" : ""));
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);

        // The key: which bar is which
        var key = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, -2, 0, 8) };
        void Key(string resource, double opacity, string label)
        {
            var swatch = new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2), Opacity = opacity, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            swatch.SetResourceReference(Border.BackgroundProperty, resource);
            key.Children.Add(swatch);
            var t = new TextBlock { Text = label, FontSize = 11.5, Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Center };
            t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            key.Children.Add(t);
        }
        Key("Ob.Record", 1, "Words dictated");
        Key("Ob.Strong", ReadOpacity, "Words read aloud");
        DockPanel.SetDock(key, Dock.Top);
        root.Children.Add(key);
        if (dictated + read == 0) { root.Children.Add(Empty("Dictate or read something aloud and your words per day appear here.")); return root; }

        var max = days.Max(d => Math.Max(d.Words, d.WordsRead));
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < days.Count; i++)
        {
            var d = days[i];
            var isToday = i == days.Count - 1;
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            // Two bars side by side: dictated, then read aloud. The whole day is the hover target.
            var pair = new Grid { Background = Brushes.Transparent, Margin = new Thickness(2, 0, 2, 0) };
            pair.ColumnDefinitions.Add(new ColumnDefinition());
            pair.ColumnDefinitions.Add(new ColumnDefinition());
            pair.Children.Add(Bar(d.Words, max, "Ob.Record", 1, 0));
            pair.Children.Add(Bar(d.WordsRead, max, "Ob.Strong", ReadOpacity, 1));
            pair.ToolTip = $"{d.Day:dddd d MMMM}\n{d.Words:N0} words dictated in {d.Dictations} dictation{(d.Dictations == 1 ? "" : "s")}" +
                           $"\n{d.WordsRead:N0} words read aloud";
            Grid.SetColumn(pair, i);
            grid.Children.Add(pair);

            var tick = new TextBlock
            {
                Text = isToday ? "today" : Short(d.Day.ToString("ddd")), FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 4, 0, 0), FontWeight = isToday ? FontWeights.SemiBold : FontWeights.Normal,
            };
            tick.SetResourceReference(TextBlock.ForegroundProperty, isToday ? "Ob.Text" : "Ob.Muted");
            Grid.SetColumn(tick, i);
            Grid.SetRow(tick, 2);
            grid.Children.Add(tick);
        }
        var baseline = new Border();
        baseline.SetResourceReference(Border.BackgroundProperty, "Ob.Divider");
        Grid.SetRow(baseline, 1);
        Grid.SetColumnSpan(baseline, days.Count);
        grid.Children.Add(baseline);
        root.Children.Add(grid);
        return root;
    }

    /// <summary>The read-aloud bars: the strong colour, toned down so the two series tell apart in every scheme.</summary>
    const double ReadOpacity = 0.45;

    /// <summary>One bar of a day, as a share of the busiest day.</summary>
    static FrameworkElement Bar(int words, int max, string resource, double opacity, int column)
    {
        var f = max > 0 ? words / (double)max : 0;
        var cell = new Grid { Margin = new Thickness(1, 0, 1, 0) };
        cell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1 - f, GridUnitType.Star) });
        cell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(f, GridUnitType.Star) });
        var bar = new Border { CornerRadius = new CornerRadius(3, 3, 0, 0), MinHeight = words > 0 ? 2 : 0, Opacity = opacity };
        bar.SetResourceReference(Border.BackgroundProperty, resource);
        Grid.SetRow(bar, 1);
        cell.Children.Add(bar);
        Grid.SetColumn(cell, column);
        return cell;
    }

    static string Short(string day) => day.Length <= 2 ? day : day[..2];

    /// <summary>The apps dictated into most, as horizontal bars with their counts.</summary>
    FrameworkElement AppsChart(IReadOnlyList<(string App, int Count)> apps)
    {
        var root = new DockPanel();
        var header = Header("WHERE YOUR WORDS GO", "dictations per app · 30 days");
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        if (apps.Count == 0) { root.Children.Add(Empty("The apps you dictate into appear here.")); return root; }

        var max = apps.Max(a => a.Count);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.9, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.4, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var i = 0; i < apps.Count; i++)
        {
            var (app, count) = apps[i];
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MaxHeight = 34 });
            var name = new TextBlock { Text = app, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 10, 0) };
            Grid.SetRow(name, i);
            grid.Children.Add(name);

            var f = count / (double)max;
            var track = new Grid { VerticalAlignment = VerticalAlignment.Center, Height = 8, Background = Brushes.Transparent };
            track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(f, GridUnitType.Star) });
            track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - f, GridUnitType.Star) });
            var bar = new Border { CornerRadius = new CornerRadius(4), MinWidth = 4 };
            bar.SetResourceReference(Border.BackgroundProperty, i == 0 ? "Ob.Record" : "Ob.Strong");
            track.Children.Add(bar);
            track.ToolTip = $"{app}: {count} dictation{(count == 1 ? "" : "s")}";
            Grid.SetRow(track, i);
            Grid.SetColumn(track, 1);
            grid.Children.Add(track);

            var n = new TextBlock { Text = count.ToString(), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
            n.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            Grid.SetRow(n, i);
            Grid.SetColumn(n, 2);
            grid.Children.Add(n);
        }
        root.Children.Add(grid);
        return root;
    }
}
