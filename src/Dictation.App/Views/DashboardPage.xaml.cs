using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;
using Dictation.Core.Settings;
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
        Loaded += async (_, _) => { AttachNotes(); _timer.Start(); await RefreshAsync(); };
        Unloaded += (_, _) => { _timer.Stop(); DetachNotes(); };
        BuildNotesCell();
        Build();
    }

    /// <summary>The speech dial's number: free the speech model's memory right away.</summary>
    async void UnloadSpeechNow()
    {
        await App.UnloadNowAsync(speech: true, ai: false, voice: false);
        Build(); // the dial now reads "off"
    }

    /// <summary>The History dial's number: copy the last dictation's AI edit (what the AI wanted to insert); without one, what went in.</summary>
    void CopyLastDictation()
    {
        var last = App.Services.History.Entries.OrderByDescending(x => x.Time).FirstOrDefault();
        var text = last == null ? "" : last.AiOutput is { Length: > 0 } ai ? ai : last.Final.Length > 0 ? last.Final : last.Transcript;
        if (text.Length == 0) { ShowToast("Nothing to copy yet: dictate something first."); return; }
        try { Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            ShowToast("The clipboard is busy; try again in a moment.");
            return;
        }
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        ShowToast($"Copied the last dictation's {(last!.AiOutput is { Length: > 0 } ? "AI edit" : "text")} ({words:N0} word{(words == 1 ? "" : "s")}, {last.When}) to the clipboard.");
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
        "History" => "History",
        "Dictated today" or "Turnaround" => "Analytics", // the same figures over time
        "Read aloud today" => "ReadAloud",
        "AI edits kept" => "SpeechToText", // the profiles, whose instructions and safety net decide what is kept
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

        // ----- the signal path: microphone → speech recognition → AI cleanup → insert, with read aloud branching off -----
        var dictating = sv.Controller.State != DictationState.Idle;
        var speechModel = SpeechModels.For(p, s.Asr);
        var speechLoaded = string.Equals(sv.Speech.LoadedModel, speechModel, StringComparison.OrdinalIgnoreCase);
        var voiceId = App.VoiceFor(p);
        var windowsVoice = VoiceCatalog.IsWindowsVoice(voiceId);
        var installed = VoiceCatalog.IsInstalled(voiceId);
        var lastApp = entries.OrderByDescending(x => x.Time).FirstOrDefault()?.AppName;
        var nodes = new[]
        {
            new PathNode("MIC", string.IsNullOrWhiteSpace(s.MicrophoneName) ? "Default microphone" : s.MicrophoneName!,
                dictating ? "Recording" : "Ready", dictating ? Dot.Busy : Dot.Ok, () => TheApp.ShowPage("Audio")),
            new PathNode("SPEECH", speechModel,
                (s.Asr.Device == "auto" ? "GPU if available" : s.Asr.Device) + " // " + (dictating ? "listening" : speechLoaded ? "loaded" : "not loaded"),
                dictating ? Dot.Busy : speechLoaded ? Dot.Ok : Dot.Off, () => TheApp.ShowPage("Models")),
            p.AutoProcess
                ? new PathNode(cloud ? "AI // CLOUD" : "AI", aiModel,
                    p.Name + " // " + (cloud ? (s.Cloud.KeepOffline ? "blocked offline" : "ready") : aiLoaded ? "loaded" : "not loaded"),
                    cloud ? (s.Cloud.KeepOffline ? Dot.Busy : Dot.Ok) : aiLoaded ? Dot.Ok : Dot.Off,
                    () => ((MainWindow)Window.GetWindow(this)!).ShowProfile(p))
                : new PathNode("AI", "No AI", p.Name + " // raw words", Dot.Off, () => ((MainWindow)Window.GetWindow(this)!).ShowProfile(p)),
            new PathNode("INSERT", s.Insertion switch { InsertionMode.Typing => "Type", InsertionMode.Clipboard => "Paste", _ => "Paste or type" }
                    + (s.TypeWhileSpeaking && !p.ShowPreview ? " // live" : p.ShowPreview ? " // preview" : ""),
                lastApp == null ? "at the cursor" : "last → " + lastApp, Dot.Ok, () => TheApp.ShowPage("General")),
        };
        var voice = new PathNode("READ ALOUD", installed ? VoiceCatalog.ShortName(voiceId) : "Not installed",
            windowsVoice ? "ready" : sv.Tts.IsRunning ? "loaded" : installed ? "idle" : "downloads on first use",
            windowsVoice || sv.Tts.IsRunning ? Dot.Ok : Dot.Off, () => TheApp.ShowPage("ReadAloud"));

        string unloadNote;
        if (s.UnloadAfterMinutes < 0) unloadNote = "Models unload right after use";
        else if (s.UnloadAfterMinutes == 0) unloadNote = "Models stay loaded";
        else if (!sv.Speech.IsReady && _loadedAi.Count == 0) unloadNote = "Nothing loaded";
        else
        {
            var left = TimeSpan.FromMinutes(s.UnloadAfterMinutes) - (now - sv.Controller.LastActivity);
            if (left < TimeSpan.Zero) left = TimeSpan.Zero;
            unloadNote = $"Unload in {(int)left.TotalMinutes:00}:{left.Seconds:00}";
        }
        PathCell.Child = SignalPath(nodes, voice, p.ReadAloudAfterInsert, s.Hotkey, unloadNote);

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

        // The last three dictations with the current speech and AI models, leaving out any that had to load a model first.
        var aiUsed = p.AutoProcess ? aiModel : "";
        var (turn, turnCount) = usage.RecentTurnaround(speechModel, aiUsed);
        Dials.Children.Add(Dial(turn is { } f ? Math.Clamp(f / 10.0, 0, 1) : 0, turn is { } f2 ? $"{f2:0.0} s" : "—",
            "Turnaround", turnCount == 0 ? "no runs yet with these models loaded"
                : $"last {turnCount} · {speechModel}{(aiUsed.Length > 0 ? " + " + aiUsed : ", no AI")}, models already loaded", fan: true));

        var kept = usage.AiKeptShare(now);
        Dials.Children.Add(Dial(kept ?? 0, kept is { } k ? $"{k:P0}" : "—", "AI edits kept", "last 30 days"));

        Dials.Children.Add(Dial(s.HistoryLimit > 0 ? entries.Count / (double)s.HistoryLimit : entries.Count > 0 ? 1 : 0,
            entries.Count.ToString(), "History", s.HistoryLimit > 0 ? $"of {s.HistoryLimit} kept" : "all kept, no limit",
            entries.Count > 0 ? CopyLastDictation : null, "Click to copy the last dictation's AI edit"));

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

        // The charts (words per day, output by app) moved to Analytics in 4.2.
    }

    // ===== pieces =====

    FontFamily Mono => (FontFamily)FindResource("Ob.Mono");
    Style Readout => (Style)FindResource("MonoLabel");

    /// <summary>One step of the signal path: what it is, the model or device, and how it is doing.</summary>
    sealed record PathNode(string Label, string Title, string Status, Dot State, Action Open);

    // Drawn at a design size and scaled to the cell. One row when the cell can show it at full size (a wide window);
    // otherwise two levels, mic → speech above and AI → insert below, so each step has more room and its text stays
    // larger. Whichever shows the text larger is used.
    double _pathWidth = 900;
    bool _pathTwoLevel;
    const double PathHeight = 210, PathY = 92, NodeRadius = 22, BranchY = 188, StepWidth = 230;
    const double TwoWidth = 760, TwoHeight = 350, TwoY1 = 70, TwoY2 = 220, TwoCol0 = 190, TwoCol1 = 545, TwoColWidth = 340,
        TwoFont = 1.2, TwoTurnX = 735;

    /// <summary>The layout for a cell of this size: one row (and how wide to draw it), or two levels.</summary>
    static (bool TwoLevel, double Width) PathLayout(Size cell)
    {
        var width = Math.Clamp(PathHeight * cell.Width / cell.Height, 4 * StepWidth, 2400);
        var oneRow = Math.Min(cell.Width / width, cell.Height / PathHeight);
        var twoLevels = Math.Min(cell.Width / TwoWidth, cell.Height / TwoHeight) * TwoFont; // how large the text comes out
        return (oneRow < 1 && twoLevels > oneRow, width);
    }

    /// <summary>
    /// The signal path, drawn like an instrument diagram: a line through the four steps, each a node (core filled when
    /// ready, hollow when off, the accent while busy) in a ring of ticks, with read aloud branching off the insert step
    /// (dashed: it only runs when the profile reads aloud, or on demand). In one row across a wide cell, or in two
    /// levels that turn at the right. Every node opens its page.
    /// </summary>
    FrameworkElement SignalPath(PathNode[] nodes, PathNode voice, bool readsAloud, string hotkey, string unloadNote)
    {
        var root = new DockPanel();

        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var keys = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var parts = hotkey.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        for (var i = 0; i < parts.Length; i++)
        {
            if (i > 0) keys.Children.Add(new TextBlock { Text = "+", Style = Readout, Margin = new Thickness(4, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center });
            var chip = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), Padding = new Thickness(8, 1, 8, 1) };
            chip.SetResourceReference(Border.BorderBrushProperty, "Ob.Text");
            chip.Child = new TextBlock { Text = parts[i].ToUpper(), FontFamily = Mono, FontSize = 12 };
            keys.Children.Add(chip);
        }
        keys.Children.Add(new TextBlock { Text = "→ START", Style = Readout, FontSize = 12, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(keys, Dock.Right);
        head.Children.Add(keys);
        head.Children.Add(new TextBlock { Text = "SIGNAL PATH", Style = Readout, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        var foot = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
        var unload = new TextBlock { Text = unloadNote.ToUpper(), FontFamily = Mono, FontSize = 12, FontWeight = FontWeights.Bold };
        unload.SetResourceReference(TextBlock.ForegroundProperty, unloadNote.StartsWith("Unload in") ? "Ob.Accent" : "Ob.Muted");
        DockPanel.SetDock(unload, Dock.Right);
        foot.Children.Add(unload);
        foot.Children.Add(new TextBlock { Text = "CLICK A NODE TO OPEN ITS SETTINGS", Style = Readout, FontSize = 12 });
        DockPanel.SetDock(foot, Dock.Bottom);
        root.Children.Add(foot);

        void Wire(Canvas c, params Point[] points)
        {
            var line = new Polyline { Points = new PointCollection(points), StrokeThickness = 1 };
            line.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
            c.Children.Add(line);
        }

        // An arrowhead at (x, y) pointing along (dx, dy), one of the four directions.
        void Arrow(Canvas c, double x, double y, double dx, double dy)
        {
            var arrow = new Polyline
            {
                Points = new PointCollection { new(x - 3 * dx - 4 * dy, y - 3 * dy - 4 * dx), new(x + 3 * dx, y + 3 * dy), new(x - 3 * dx + 4 * dy, y - 3 * dy + 4 * dx) },
                StrokeThickness = 1,
            };
            arrow.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
            c.Children.Add(arrow);
        }

        // Read aloud: a dashed branch off the insert node to a pill with the voice; place(pill) positions it once measured.
        void ReadAloud(Canvas c, double font, Point[] branchPoints, Action<Border> place)
        {
            var branch = new Polyline { Points = new PointCollection(branchPoints), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 3 } };
            branch.SetResourceReference(Shape.StrokeProperty, readsAloud ? "Ob.Text" : "Ob.Muted");
            c.Children.Add(branch);
            var pill = new Border
            {
                BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(11 * font), Padding = new Thickness(14, 4, 14, 4),
                Cursor = Cursors.Hand, ToolTip = $"Read aloud: {voice.Title} ({voice.Status})" + (readsAloud ? " — this profile reads each dictation aloud" : ""),
            };
            pill.SetResourceReference(Border.BorderBrushProperty, "Ob.Text");
            pill.SetResourceReference(Border.BackgroundProperty, "Ob.Window");
            var pillText = new StackPanel { Orientation = Orientation.Horizontal };
            pillText.Children.Add(Node(voice.State, small: true));
            var pillLabel = new TextBlock
            {
                Text = $"{voice.Label} // {voice.Title} // {voice.Status}".ToUpper(), FontFamily = Mono, FontSize = 12.5 * font,
                Margin = new Thickness(7, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
            };
            pillLabel.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            pillText.Children.Add(pillLabel);
            pill.Child = pillText;
            AccentOnHover(pill, wash: false,
                (pill, Border.BorderBrushProperty, "Ob.Text"),
                (pillLabel, TextBlock.ForegroundProperty, "Ob.Text"));
            pill.MouseLeftButtonUp += (_, e) => { e.Handled = true; voice.Open(); };
            pill.Loaded += (_, _) => place(pill);
            Panel.SetZIndex(pill, 1); // above the step columns, which are click targets too
            place(pill);
            c.Children.Add(pill);
        }

        Canvas DrawRow(double width)
        {
            var c = new Canvas { Width = width, Height = PathHeight };
            double X(int i) => StepWidth / 2 + i * (width - StepWidth / 2 - 150) / (nodes.Length - 1);
            Wire(c, new Point(X(0), PathY), new Point(X(nodes.Length - 1), PathY));
            for (var i = 0; i < nodes.Length - 1; i++) Arrow(c, (X(i) + X(i + 1)) / 2, PathY, 1, 0); // halfway to the next node

            // Read aloud: down from the insert node and back under the AI node
            var last = X(nodes.Length - 1);
            var pillRight = X(nodes.Length - 2) + 80;
            ReadAloud(c, 1, new[] { new Point(last + NodeRadius, PathY), new Point(last + 90, PathY), new Point(last + 90, BranchY), new Point(pillRight, BranchY) },
                pill =>
                {
                    Canvas.SetLeft(pill, pillRight - (pill.ActualWidth > 0 ? pill.ActualWidth : 200));
                    Canvas.SetTop(pill, BranchY - (pill.ActualHeight > 0 ? pill.ActualHeight : 26) / 2);
                });

            for (var i = 0; i < nodes.Length; i++) c.Children.Add(PathStep(nodes[i], X(i), PathY, first: i == 0, StepWidth, 1));
            return c;
        }

        // Two levels: mic → speech, a turn down the right, then AI → insert going back left; read aloud below insert.
        Canvas DrawTwoLevels()
        {
            var c = new Canvas { Width = TwoWidth, Height = TwoHeight };
            Wire(c, new Point(TwoCol0 + NodeRadius, TwoY1), new Point(TwoCol1 - NodeRadius, TwoY1));
            Arrow(c, (TwoCol0 + TwoCol1) / 2, TwoY1, 1, 0);
            Wire(c, new Point(TwoCol1 + NodeRadius, TwoY1), new Point(TwoTurnX, TwoY1), new Point(TwoTurnX, TwoY2), new Point(TwoCol1 + NodeRadius, TwoY2));
            Arrow(c, TwoTurnX, (TwoY1 + TwoY2) / 2, 0, 1);
            Wire(c, new Point(TwoCol1 - NodeRadius, TwoY2), new Point(TwoCol0 + NodeRadius, TwoY2));
            Arrow(c, (TwoCol0 + TwoCol1) / 2, TwoY2, -1, 0);

            var pillY = TwoY2 + 108;
            ReadAloud(c, TwoFont, new[] { new Point(TwoCol0 - NodeRadius, TwoY2), new Point(20, TwoY2), new Point(20, pillY), new Point(40, pillY) },
                pill =>
                {
                    Canvas.SetLeft(pill, 40);
                    Canvas.SetTop(pill, pillY - (pill.ActualHeight > 0 ? pill.ActualHeight : 30) / 2);
                });

            c.Children.Add(PathStep(nodes[0], TwoCol0, TwoY1, first: true, TwoColWidth, TwoFont));
            c.Children.Add(PathStep(nodes[1], TwoCol1, TwoY1, first: false, TwoColWidth, TwoFont));
            c.Children.Add(PathStep(nodes[2], TwoCol1, TwoY2, first: false, TwoColWidth, TwoFont));
            c.Children.Add(PathStep(nodes[3], TwoCol0, TwoY2, first: false, TwoColWidth, TwoFont));
            return c;
        }

        Canvas Draw(bool twoLevels, double width) => twoLevels && nodes.Length == 4 ? DrawTwoLevels() : DrawRow(width);

        // Redrawn to the cell's own shape whenever it resizes, so the scaled drawing fills it instead of shrinking to fit
        // a fixed shape (and its text with it).
        var view = new Viewbox { Stretch = Stretch.Uniform, Child = Draw(_pathTwoLevel, _pathWidth) };
        var host = new Border { Background = Brushes.Transparent, Child = view };
        host.SizeChanged += (_, e) =>
        {
            if (e.NewSize.Width < 1 || e.NewSize.Height < 1) return;
            var (twoLevels, width) = PathLayout(e.NewSize);
            var same = twoLevels == _pathTwoLevel && (twoLevels || Math.Abs(width - _pathWidth) < 1);
            // The next refresh starts from this layout, so it doesn't flicker.
            _pathTwoLevel = twoLevels;
            _pathWidth = width;
            if (!same || view.Child is not Canvas) view.Child = Draw(twoLevels, width);
        };

        root.Children.Add(host);
        return root;
    }

    /// <summary>While the pointer is over <paramref name="target"/> (something that can be clicked), the given parts take
    /// the accent and the target a faint accent tint; they go back to their own colours when it leaves.</summary>
    static void AccentOnHover(FrameworkElement target, bool wash, params (FrameworkElement Part, DependencyProperty Property, string Key)[] parts)
    {
        var background = (target as Panel)?.Background ?? (target as Border)?.Background;
        target.MouseEnter += (_, _) =>
        {
            foreach (var (part, property, _) in parts) part.SetResourceReference(property, "Ob.Accent");
            if (wash) SetBackground(target, null);
        };
        target.MouseLeave += (_, _) =>
        {
            foreach (var (part, property, key) in parts) part.SetResourceReference(property, key);
            if (wash) SetBackground(target, background);
        };
    }

    static void SetBackground(FrameworkElement target, Brush? restore)
    {
        var property = target is Panel ? Panel.BackgroundProperty : Border.BackgroundProperty;
        if (restore == null) target.SetResourceReference(property, "Ob.AccentWash");
        else target.SetValue(property, restore);
    }

    /// <summary>A node of the signal path at (<paramref name="x"/>, <paramref name="y"/>), its label above and its model
    /// and status below, in a column <paramref name="w"/> wide with its text <paramref name="font"/> times the usual
    /// size; the whole column is the click target.</summary>
    FrameworkElement PathStep(PathNode n, double x, double y, bool first, double w, double font)
    {
        var col = new Grid { Width = w, Height = 108 + 46 * font, Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = $"{n.Title}: {n.Status}" };
        var label = new TextBlock
        {
            Text = n.Label, FontFamily = Mono, FontSize = 15 * font, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 6 - 4 * (font - 1), 0, 0), VerticalAlignment = VerticalAlignment.Top,
        };
        col.Children.Add(label);

        var dial = new Canvas { Width = 80, Height = 80, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 30, 0, 0) };
        for (var k = 0; k < 12; k++)
        {
            var a = k / 12.0 * Math.PI * 2;
            var tick = new Ellipse { Width = 2, Height = 2, Opacity = 0.5 };
            tick.SetResourceReference(Shape.FillProperty, "Ob.Text");
            Canvas.SetLeft(tick, 40 + Math.Cos(a) * 30 - 1);
            Canvas.SetTop(tick, 40 + Math.Sin(a) * 30 - 1);
            dial.Children.Add(tick);
        }
        var ring = new Ellipse { Width = NodeRadius * 2, Height = NodeRadius * 2, StrokeThickness = 1 };
        ring.SetResourceReference(Shape.StrokeProperty, n.State == Dot.Busy ? "Ob.Accent" : "Ob.Text");
        ring.SetResourceReference(Shape.FillProperty, "Ob.Window");
        Canvas.SetLeft(ring, 40 - NodeRadius);
        Canvas.SetTop(ring, 40 - NodeRadius);
        dial.Children.Add(ring);
        var size = first ? 12 : 8;
        var core = new Ellipse { Width = size, Height = size };
        if (n.State == Dot.Off)
        {
            core.StrokeThickness = 1;
            core.SetResourceReference(Shape.StrokeProperty, "Ob.Muted");
        }
        else core.SetResourceReference(Shape.FillProperty, n.State == Dot.Busy ? "Ob.Accent" : "Ob.Strong");
        Canvas.SetLeft(core, 40 - size / 2.0);
        Canvas.SetTop(core, 40 - size / 2.0);
        dial.Children.Add(core);
        col.Children.Add(dial);

        var below = new StackPanel { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 108, 0, 0) };
        var title = new TextBlock
        {
            Text = n.Title.ToUpper(), FontFamily = Mono, FontSize = 13.5 * font, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = w - 8,
        };
        below.Children.Add(title);
        var status = new TextBlock
        {
            Text = n.Status.ToUpper(), FontFamily = Mono, FontSize = 12 * font, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = w - 8, Margin = new Thickness(0, 2, 0, 0),
        };
        status.SetResourceReference(TextBlock.ForegroundProperty, n.State == Dot.Busy ? "Ob.Accent" : "Ob.Muted");
        below.Children.Add(status);
        col.Children.Add(below);

        label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        title.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        AccentOnHover(col, wash: true,
            (label, TextBlock.ForegroundProperty, "Ob.Text"),
            (title, TextBlock.ForegroundProperty, "Ob.Text"),
            (ring, Shape.StrokeProperty, n.State == Dot.Busy ? "Ob.Accent" : "Ob.Text"));
        col.MouseLeftButtonUp += (_, e) => { e.Handled = true; n.Open(); };
        // The dial's centre sits at (x, y): 70 below the column's top.
        Canvas.SetLeft(col, x - w / 2);
        Canvas.SetTop(col, y - 70);
        return col;
    }

    static FrameworkElement Node(Dot dot, bool small = false)
    {
        var g = new Grid { Width = small ? 11 : 16, Height = small ? 11 : 16, VerticalAlignment = VerticalAlignment.Center };
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
            AccentOnHover(big, wash: false, (big, TextBlock.ForegroundProperty, accent ? "Ob.Accent" : "Ob.Text"));
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
}
