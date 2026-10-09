using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;
using Dictation.Core.Setup;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// At a glance, without scrolling: what is active and loaded (the signal path), how dictation is going (meters), and
/// where the words go (charts). Drawn as an instrument panel: cells sharing hairline edges, rings of dots, block bars.
/// The accent marks only what changes while you watch (today's words, the unload countdown). Everything sizes to the
/// window and refreshes every few seconds.
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

    /// <summary>The History dial's number: copy the text of the last dictation (what was inserted, after any AI edit).</summary>
    void CopyLastDictation()
    {
        var last = App.Services.History.Entries.OrderByDescending(x => x.Time).FirstOrDefault();
        var text = last == null ? "" : last.Final.Length > 0 ? last.Final : last.AiOutput is { Length: > 0 } ai ? ai : last.Transcript;
        if (text.Length == 0) { ShowToast("Nothing to copy yet: dictate something first."); return; }
        try { Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            ShowToast("The clipboard is busy; try again in a moment.");
            return;
        }
        var words = last!.Words;
        ShowToast($"Copied the last dictation ({words:N0} word{(words == 1 ? "" : "s")}, {last.When}) to the clipboard.");
    }

    readonly DispatcherTimer _toastTimer = new() { Interval = TimeSpan.FromSeconds(2.5) };

    void ShowToast(string message)
    {
        ToastText.Text = message;
        Toast.BeginAnimation(OpacityProperty, new System.Windows.Media.Animation.DoubleAnimation(1, TimeSpan.FromMilliseconds(120)));
        _toastTimer.Stop();
        _toastTimer.Tick -= HideToast;
        _toastTimer.Tick += HideToast;
        _toastTimer.Start();
    }

    void HideToast(object? sender, EventArgs e)
    {
        _toastTimer.Stop();
        Toast.BeginAnimation(OpacityProperty, new System.Windows.Media.Animation.DoubleAnimation(0, TimeSpan.FromMilliseconds(300)));
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

        Clock.Text = $"{now:dddd d MMMM} — {now:t}".ToUpper();
        Summary.Text = sv.Controller.State != DictationState.Idle
            ? $"Dictating with {p.Name} right now."
            : $"Press {s.Hotkey} to dictate with {p.Name}. Select text and press {s.SpeakHotkey} to hear it.";
        Footer.Text = ($"{AppInfo.Name} {AppInfo.VersionText}  //  {sv.Usage.TotalWords:N0} words dictated in all  //  " +
                      (s.Cloud.KeepOffline ? "everything stays on this PC" : "cloud AI allowed") +
                      $"  //  {s.CycleProfileHotkey} switches profile  //  models unload {(s.UnloadAfterMinutes < 0 ? unload : "after " + unload + " unused")}").ToUpper();

        // ----- the signal path -----
        Tiles.Children.Clear();
        var traits = new List<string>();
        if (p.AutoProcess && p.RewriteWhole) traits.Add("rewrites whole");
        if (p.ShowPreview) traits.Add("previews");
        else if (s.TypeWhileSpeaking) traits.Add("types as you speak");
        if (p.ReadAloudAfterInsert) traits.Add("reads aloud");
        Tiles.Children.Add(Tile(1, "PROFILE", p.Name,
            p.AutoProcess ? Dot.Ok : Dot.Off, p.AutoProcess ? (cloud ? "AI · cloud" : "AI · on this PC") : "No AI · raw words",
            traits.Count == 0 ? p.Description : string.Join(" · ", traits),
            () => ((MainWindow)Window.GetWindow(this)!).ShowProfile(p)));

        var dictating = sv.Controller.State != DictationState.Idle;
        var speechModel = SpeechModels.For(p, s.Asr);
        var speechLoaded = string.Equals(sv.Speech.LoadedModel, speechModel, StringComparison.OrdinalIgnoreCase);
        Tiles.Children.Add(Tile(2, "SPEECH", speechModel,
            dictating || speechLoaded ? Dot.Ok : Dot.Busy,
            dictating ? "Dictating…" : speechLoaded ? "Loaded" : "Not loaded · loads when you dictate",
            (s.Asr.Device == "auto" ? "GPU if available" : s.Asr.Device.ToUpperInvariant()) + " · " +
            (string.IsNullOrEmpty(s.Asr.Language) ? "any language" : s.Asr.Language),
            () => TheApp.ShowPage("Models")));

        Tiles.Children.Add(Tile(3, "AI CLEANUP", p.AutoProcess ? aiModel : s.Llm.DefaultModel,
            cloud ? (s.Cloud.KeepOffline ? Dot.Busy : Dot.Ok) : aiLoaded ? Dot.Ok : Dot.Busy,
            cloud ? (s.Cloud.KeepOffline ? "Cloud · blocked by offline mode" : "Cloud · ready")
                  : aiLoaded ? "Loaded" : "Not loaded · loads when needed",
            _loadedAi.Count == 0 ? "Nothing in memory" : "In memory: " + string.Join(", ", _loadedAi),
            () => TheApp.ShowPage("Models")));

        var voiceId = App.VoiceFor(p);
        var windowsVoice = VoiceCatalog.IsWindowsVoice(voiceId);
        var installed = VoiceCatalog.IsInstalled(voiceId);
        Tiles.Children.Add(Tile(4, "READ ALOUD", installed ? VoiceCatalog.ShortName(voiceId) : "Not installed",
            windowsVoice || sv.Tts.IsRunning ? Dot.Ok : installed ? Dot.Busy : Dot.Off,
            windowsVoice ? "Windows voice · ready" : sv.Tts.IsRunning ? "Voice loaded" : installed ? "Starts when you read" : "Downloads on first use",
            $"{VoiceCatalog.Model(VoiceCatalog.ModelOf(voiceId)).Name} · {s.TtsBaseSpeed:0.0#}× · {s.SpeakHotkey}",
            () => TheApp.ShowPage("ReadAloud")));

        // ----- meters -----
        Dials.Children.Clear();
        // Figures come from the daily counts (UsageStore), which survive History being trimmed, cleared or off.
        var usage = sv.Usage;
        var days = usage.PerDay(now);
        var today = days[^1].Words;
        var best = days.Max(d => d.Words);
        Dials.Children.Add(Dial(best > 0 ? today / (double)best : 0, today.ToString("N0"), "Dictated today",
            best > 0 ? $"words · best day {best:N0}" : "no dictation yet", accent: true));
        var readToday = days[^1].WordsRead;
        var bestRead = days.Max(d => d.WordsRead);
        Dials.Children.Add(Dial(bestRead > 0 ? readToday / (double)bestRead : 0, readToday.ToString("N0"), "Read aloud today",
            bestRead > 0 ? $"words · best day {bestRead:N0}" : "nothing read yet"));

        var finish = usage.AverageFinishSeconds(now);
        Dials.Children.Add(Dial(finish is { } f ? Math.Clamp(f / 10.0, 0, 1) : 0, finish is { } f2 ? $"{f2:0.0} s" : "—",
            "Turnaround", "stop → text in place, 7 days", fan: true));

        var kept = usage.AiKeptShare(now);
        Dials.Children.Add(Dial(kept ?? 0, kept is { } k ? $"{k:P0}" : "—", "AI edits kept", "last 30 days"));

        Dials.Children.Add(Dial(s.HistoryLimit > 0 ? entries.Count / (double)s.HistoryLimit : entries.Count > 0 ? 1 : 0,
            entries.Count.ToString(), "History", s.HistoryLimit > 0 ? $"of {s.HistoryLimit} kept" : "all kept, no limit",
            entries.Count > 0 ? CopyLastDictation : null, "Click to copy the last dictation's inserted text"));

        if (dictating) Dials.Children.Add(Dial(1, "busy", "Speech model", "dictating now", accent: true));
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
                "Speech model", "until it unloads", UnloadSpeechNow, "Click to unload the speech model now", accent: true));
        }

        // ----- charts -----
        DaysCard.Child = DaysChart(days, usage.Streak(now));
        AppsCard.Child = AppsChart(usage.TopApps(now));
    }

    // ===== pieces =====

    FontFamily Mono => (FontFamily)FindResource("Ob.Mono");
    Style Readout => (Style)FindResource("MonoLabel");

    const double TileDesignWidth = 230;

    /// <summary>One step of the signal path: a node (filled when ready, hollow when off, the accent while it starts),
    /// its number and name, an arrow to the next step, and what it is and how it is doing.</summary>
    FrameworkElement Tile(int step, string label, string title, Dot dot, string status, string detail, Action open)
    {
        var panel = new StackPanel();
        var head = new DockPanel();
        var node = Node(dot);
        DockPanel.SetDock(node, Dock.Left);
        head.Children.Add(node);
        if (step < 4)
        {
            var arrow = new TextBlock { Text = "→", Style = Readout, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(arrow, Dock.Right);
            head.Children.Add(arrow);
        }
        head.Children.Add(new TextBlock
        {
            Text = $"{step:00} // {label}", Style = Readout, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0),
        });
        panel.Children.Add(head);
        panel.Children.Add(new TextBlock
        {
            Text = title, FontSize = 16, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 9, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = title,
        });
        var line = new TextBlock
        {
            Text = status.ToUpper(), FontFamily = Mono, FontSize = 10.5, Margin = new Thickness(0, 5, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = status,
        };
        line.SetResourceReference(TextBlock.ForegroundProperty, dot == Dot.Busy ? "Ob.Accent" : "Ob.Text");
        panel.Children.Add(line);
        var sub = new TextBlock { Text = detail, FontSize = 12, Margin = new Thickness(0, 4, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = detail };
        sub.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        panel.Children.Add(sub);

        // Laid out at a fixed design width, then scaled to the tile: the text grows with the window instead of staying
        // small in a big tile (and still trims long names at that width).
        panel.Width = TileDesignWidth;
        var card = new Border
        {
            Style = (Style)FindResource("DashCell"), Padding = new Thickness(14, 10, 14, 10),
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

    static FrameworkElement Node(Dot dot)
    {
        var g = new Grid { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center };
        var ring = new Ellipse { StrokeThickness = 1 };
        ring.SetResourceReference(Shape.StrokeProperty, dot == Dot.Busy ? "Ob.Accent" : "Ob.Text");
        g.Children.Add(ring);
        var core = new Ellipse { Width = 6, Height = 6 };
        if (dot == Dot.Off)
        {
            core.StrokeThickness = 1;
            core.SetResourceReference(Shape.StrokeProperty, "Ob.Track");
        }
        else core.SetResourceReference(Shape.FillProperty, dot == Dot.Busy ? "Ob.Accent" : "Ob.Strong");
        g.Children.Add(core);
        return g;
    }

    /// <summary>A meter, drawn at a fixed design size and scaled to its cell: a ring of 32 dots lit to the fraction, or
    /// (<paramref name="fan"/>) a fan of ticks with a needle.</summary>
    /// <param name="valueClick">What clicking the big number does (instead of opening the meter's page), if anything.</param>
    /// <param name="accent">The value changes while you watch: dots and number in the accent.</param>
    FrameworkElement Dial(double fraction, string value, string label, string sub, Action? valueClick = null, string? valueTip = null,
        bool accent = false, bool fan = false)
    {
        const double size = 150, cx = 75;
        var canvas = new Grid { Width = size, Height = size };
        var draw = new Canvas { Width = size, Height = size };
        if (fan) DrawFan(draw, cx, 92, fraction);
        else DrawRing(draw, cx, 64, 52, fraction, accent);
        canvas.Children.Add(draw);

        var center = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, fan ? 98 : 46, 0, 0) };
        var big = new TextBlock { Text = value, FontFamily = Mono, FontSize = 21, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center };
        big.SetResourceReference(TextBlock.ForegroundProperty, accent ? "Ob.Accent" : "Ob.Text");
        if (valueClick != null)
        {
            // The number is its own button; the rest of the meter still opens the page.
            big.Background = Brushes.Transparent;
            big.ToolTip = valueTip;
            big.TextDecorations = TextDecorations.Underline;
            big.MouseLeftButtonUp += (_, e) => { e.Handled = true; valueClick(); };
            big.Cursor = Cursors.Hand;
        }
        center.Children.Add(big);
        if (!fan)
        {
            var name = new TextBlock { Text = label.ToUpper(), Style = Readout, FontSize = 8.5, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 2, 0, 0) };
            center.Children.Add(name);
        }
        canvas.Children.Add(center);

        var note = new TextBlock
        {
            Text = fan ? label.ToUpper() : sub, FontSize = fan ? 8.5 : 10, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 2), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 144,
        };
        if (fan) note.FontFamily = Mono;
        note.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        canvas.Children.Add(note);

        var card = new Border
        {
            Style = (Style)FindResource("DashCell"), Padding = new Thickness(6),
            Child = new Viewbox { Stretch = Stretch.Uniform, Child = canvas }, ToolTip = $"{label}: {value} ({sub})",
            Cursor = Cursors.Hand,
        };
        card.MouseLeftButtonUp += (_, _) => TheApp.ShowPage(DialPage(label));
        return card;
    }

    /// <summary>A ring of dots from the top, clockwise: lit ones filled, the rest small and hollow.</summary>
    static void DrawRing(Canvas c, double cx, double cy, double r, double fraction, bool accent)
    {
        const int n = 32;
        var lit = (int)Math.Round(Math.Clamp(fraction, 0, 1) * n);
        for (var i = 0; i < n; i++)
        {
            var a = -Math.PI / 2 + i * 2 * Math.PI / n;
            var on = i < lit;
            var d = on ? 6.0 : 3.6;
            var dot = new Ellipse { Width = d, Height = d };
            if (on) dot.SetResourceReference(Shape.FillProperty, accent ? "Ob.Accent" : "Ob.Strong");
            else
            {
                dot.StrokeThickness = 0.9;
                dot.SetResourceReference(Shape.StrokeProperty, "Ob.Track");
            }
            Canvas.SetLeft(dot, cx + r * Math.Cos(a) - d / 2);
            Canvas.SetTop(dot, cy + r * Math.Sin(a) - d / 2);
            c.Children.Add(dot);
        }
    }

    /// <summary>A half circle of ticks (every third one longer) and a needle at the fraction, left to right.</summary>
    static void DrawFan(Canvas c, double cx, double cy, double fraction)
    {
        const int n = 19;
        for (var i = 0; i < n; i++)
        {
            var a = Math.PI + i * Math.PI / (n - 1);
            var major = i % 3 == 0;
            var (r1, r2) = (36.0, major ? 58.0 : 50.0);
            var tick = new Line
            {
                X1 = cx + r1 * Math.Cos(a), Y1 = cy + r1 * Math.Sin(a), X2 = cx + r2 * Math.Cos(a), Y2 = cy + r2 * Math.Sin(a),
                StrokeThickness = major ? 1.4 : 0.8,
            };
            tick.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
            c.Children.Add(tick);
        }
        var na = Math.PI + Math.Clamp(fraction, 0, 1) * Math.PI;
        var needle = new Line
        {
            X1 = cx, Y1 = cy, X2 = cx + 62 * Math.Cos(na), Y2 = cy + 62 * Math.Sin(na),
            StrokeThickness = 2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        };
        needle.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
        c.Children.Add(needle);
        var hub = new Ellipse { Width = 8, Height = 8 };
        hub.SetResourceReference(Shape.FillProperty, "Ob.Strong");
        Canvas.SetLeft(hub, cx - 4);
        Canvas.SetTop(hub, cy - 4);
        c.Children.Add(hub);
    }

    FrameworkElement Header(string title, string right)
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var r = new TextBlock { Text = right.ToUpper(), Style = Readout, TextTrimming = TextTrimming.CharacterEllipsis };
        DockPanel.SetDock(r, Dock.Right);
        header.Children.Add(r);
        var t = new TextBlock { Text = title, Style = Readout, Margin = new Thickness(0, 0, 12, 0) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        header.Children.Add(t);
        return header;
    }

    TextBlock Empty(string text)
    {
        var t = new TextBlock { Text = text, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        return t;
    }

    /// <summary>Words per day as columns: dictated in ink (today in the accent), read aloud faint beside them. Hover a
    /// day for its numbers.</summary>
    FrameworkElement DaysChart(IReadOnlyList<DayTotal> days, int streak)
    {
        var root = new DockPanel();
        var dictated = days.Sum(d => d.Words);
        var read = days.Sum(d => d.WordsRead);
        var header = Header("WORDS PER DAY // 14 DAYS", $"{dictated:N0} dictated · {read:N0} read aloud" +
                                                       (streak > 1 ? $" · {streak}-day streak" : ""));
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);

        // The key: which bar is which
        var key = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, -2, 0, 8) };
        void Key(string resource, double opacity, string label)
        {
            var swatch = new Border { Width = 9, Height = 9, Opacity = opacity, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            swatch.SetResourceReference(Border.BackgroundProperty, resource);
            key.Children.Add(swatch);
            key.Children.Add(new TextBlock { Text = label, Style = Readout, Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Center });
        }
        Key("Ob.Strong", 1, "DICTATED");
        Key("Ob.Strong", ReadOpacity, "READ ALOUD");
        Key("Ob.Accent", 1, "TODAY");
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
            pair.Children.Add(Bar(d.Words, max, isToday ? "Ob.Accent" : "Ob.Strong", 1, 0));
            pair.Children.Add(Bar(d.WordsRead, max, "Ob.Strong", ReadOpacity, 1));
            pair.ToolTip = $"{d.Day:dddd d MMMM}\n{d.Words:N0} words dictated in {d.Dictations} dictation{(d.Dictations == 1 ? "" : "s")}" +
                           $"\n{d.WordsRead:N0} words read aloud";
            Grid.SetColumn(pair, i);
            grid.Children.Add(pair);

            var tick = new TextBlock
            {
                Text = isToday ? "NOW" : Short(d.Day.ToString("ddd")).ToUpper(), Style = Readout, FontSize = 9,
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0),
                FontWeight = isToday ? FontWeights.Bold : FontWeights.Normal,
            };
            if (isToday) tick.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Accent");
            Grid.SetColumn(tick, i);
            Grid.SetRow(tick, 2);
            grid.Children.Add(tick);
        }
        var baseline = new Border();
        baseline.SetResourceReference(Border.BackgroundProperty, "Ob.Border");
        Grid.SetRow(baseline, 1);
        Grid.SetColumnSpan(baseline, days.Count);
        grid.Children.Add(baseline);
        root.Children.Add(grid);
        return root;
    }

    /// <summary>The read-aloud bars: ink, toned down so the two series tell apart.</summary>
    const double ReadOpacity = 0.3;

    /// <summary>One bar of a day, as a share of the busiest day.</summary>
    static FrameworkElement Bar(int words, int max, string resource, double opacity, int column)
    {
        var f = max > 0 ? words / (double)max : 0;
        var cell = new Grid { Margin = new Thickness(1, 0, 1, 0) };
        cell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1 - f, GridUnitType.Star) });
        cell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(f, GridUnitType.Star) });
        var bar = new Border { MinHeight = words > 0 ? 2 : 0, Opacity = opacity };
        bar.SetResourceReference(Border.BackgroundProperty, resource);
        Grid.SetRow(bar, 1);
        cell.Children.Add(bar);
        Grid.SetColumn(cell, column);
        return cell;
    }

    static string Short(string day) => day.Length <= 2 ? day : day[..2];

    const int Blocks = 20;

    /// <summary>The apps dictated into most, as rows of blocks filled to their share, with their counts.</summary>
    FrameworkElement AppsChart(IReadOnlyList<(string App, int Count)> apps)
    {
        var root = new DockPanel();
        var header = Header("OUTPUT // BY APP", "dictations · 30 days");
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        if (apps.Count == 0) { root.Children.Add(Empty("The apps you dictate into appear here.")); return root; }

        var max = apps.Max(a => a.Count);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.8, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.5, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var i = 0; i < apps.Count; i++)
        {
            var (app, count) = apps[i];
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MaxHeight = 30 });
            var name = new TextBlock
            {
                Text = app.ToUpper(), FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 10, 0), ToolTip = app,
            };
            Grid.SetRow(name, i);
            grid.Children.Add(name);

            var filled = Math.Max(1, (int)Math.Round(count / (double)max * Blocks));
            var track = new UniformGrid { Rows = 1, Columns = Blocks, Height = 10, VerticalAlignment = VerticalAlignment.Center, Background = Brushes.Transparent };
            for (var b = 0; b < Blocks; b++)
            {
                var block = new Border { BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 2, 0) };
                block.SetResourceReference(Border.BorderBrushProperty, b < filled ? "Ob.Strong" : "Ob.Divider");
                if (b < filled) block.SetResourceReference(Border.BackgroundProperty, "Ob.Strong");
                track.Children.Add(block);
            }
            track.ToolTip = $"{app}: {count} dictation{(count == 1 ? "" : "s")}";
            Grid.SetRow(track, i);
            Grid.SetColumn(track, 1);
            grid.Children.Add(track);

            var n = new TextBlock { Text = count.ToString("N0"), FontFamily = Mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
            Grid.SetRow(n, i);
            Grid.SetColumn(n, 2);
            grid.Children.Add(n);
        }
        root.Children.Add(grid);
        return root;
    }
}
