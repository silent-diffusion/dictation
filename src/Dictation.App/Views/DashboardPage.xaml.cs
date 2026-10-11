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

        var finish = usage.AverageFinishSeconds(now);
        Dials.Children.Add(Dial(finish is { } f ? Math.Clamp(f / 10.0, 0, 1) : 0, finish is { } f2 ? $"{f2:0.0} s" : "—",
            "Turnaround", "stop → text in place, 7 days", fan: true));

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

        // ----- charts -----
        DaysCard.Child = DaysChart(days, usage.Streak(now));
        AppsCard.Child = AppsChart(usage.TopApps(now));
    }

    // ===== pieces =====

    FontFamily Mono => (FontFamily)FindResource("Ob.Mono");
    Style Readout => (Style)FindResource("MonoLabel");

    /// <summary>One step of the signal path: what it is, the model or device, and how it is doing.</summary>
    sealed record PathNode(string Label, string Title, string Status, Dot State, Action Open);

    const double PathWidth = 900, PathHeight = 200, PathY = 86, NodeRadius = 22;

    /// <summary>
    /// The signal path, drawn like an instrument diagram at a fixed design size and scaled to the cell: a line through
    /// the four steps, each a node (core filled when ready, hollow when off, the accent while busy) in a ring of ticks,
    /// with read aloud branching off the insert step (dashed: it only runs when the profile reads aloud, or on demand).
    /// Every node opens its page.
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
            chip.Child = new TextBlock { Text = parts[i].ToUpper(), FontFamily = Mono, FontSize = 10.5 };
            keys.Children.Add(chip);
        }
        keys.Children.Add(new TextBlock { Text = "→ START", Style = Readout, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(keys, Dock.Right);
        head.Children.Add(keys);
        head.Children.Add(new TextBlock { Text = "SIGNAL PATH", Style = Readout, VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        var foot = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
        var unload = new TextBlock { Text = unloadNote.ToUpper(), FontFamily = Mono, FontSize = 10.5, FontWeight = FontWeights.Bold };
        unload.SetResourceReference(TextBlock.ForegroundProperty, unloadNote.StartsWith("Unload in") ? "Ob.Accent" : "Ob.Muted");
        DockPanel.SetDock(unload, Dock.Right);
        foot.Children.Add(unload);
        foot.Children.Add(new TextBlock { Text = "CLICK A NODE TO OPEN ITS SETTINGS", Style = Readout });
        DockPanel.SetDock(foot, Dock.Bottom);
        root.Children.Add(foot);

        var c = new Canvas { Width = PathWidth, Height = PathHeight };
        double X(int i) => 90 + i * (PathWidth - 180) / (nodes.Length - 1);

        var line = new Line { X1 = X(0), Y1 = PathY, X2 = X(nodes.Length - 1), Y2 = PathY, StrokeThickness = 1 };
        line.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
        c.Children.Add(line);
        for (var i = 0; i < nodes.Length - 1; i++)
        {
            // An arrowhead halfway to the next node
            var mid = (X(i) + X(i + 1)) / 2;
            var arrow = new Polyline { Points = new PointCollection { new(mid - 3, PathY - 4), new(mid + 3, PathY), new(mid - 3, PathY + 4) }, StrokeThickness = 1 };
            arrow.SetResourceReference(Shape.StrokeProperty, "Ob.Text");
            c.Children.Add(arrow);
        }

        // Read aloud: a dashed branch from the insert node, down and back under the AI node
        var last = X(nodes.Length - 1);
        var pillX = X(nodes.Length - 2);
        var branch = new Polyline
        {
            Points = new PointCollection { new(last, PathY + NodeRadius), new(last, 172), new(pillX + 80, 172) },
            StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 3 },
        };
        branch.SetResourceReference(Shape.StrokeProperty, readsAloud ? "Ob.Text" : "Ob.Muted");
        c.Children.Add(branch);
        var pill = new Border
        {
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(11), Padding = new Thickness(12, 3, 12, 3),
            Cursor = Cursors.Hand, ToolTip = $"Read aloud: {voice.Title} ({voice.Status})" + (readsAloud ? " — this profile reads each dictation aloud" : ""),
        };
        pill.SetResourceReference(Border.BorderBrushProperty, "Ob.Text");
        pill.SetResourceReference(Border.BackgroundProperty, "Ob.Window");
        var pillText = new StackPanel { Orientation = Orientation.Horizontal };
        pillText.Children.Add(Node(voice.State, small: true));
        pillText.Children.Add(new TextBlock
        {
            Text = $"{voice.Label} // {voice.Title} // {voice.Status}".ToUpper(), FontFamily = Mono, FontSize = 10,
            Margin = new Thickness(7, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
        });
        pill.Child = pillText;
        pill.MouseLeftButtonUp += (_, e) => { e.Handled = true; voice.Open(); };
        pill.Loaded += (_, _) =>
        {
            Canvas.SetLeft(pill, pillX + 80 - pill.ActualWidth);
            Canvas.SetTop(pill, 172 - pill.ActualHeight / 2);
        };
        Canvas.SetLeft(pill, pillX - 120);
        Canvas.SetTop(pill, 161);
        c.Children.Add(pill);

        for (var i = 0; i < nodes.Length; i++) c.Children.Add(PathStep(nodes[i], X(i), first: i == 0));

        root.Children.Add(new Viewbox { Stretch = Stretch.Uniform, Child = c });
        return root;
    }

    /// <summary>A node of the signal path with its label above and its model and status below; the whole column is the
    /// click target.</summary>
    FrameworkElement PathStep(PathNode n, double x, bool first)
    {
        const double w = 190;
        var col = new Grid { Width = w, Height = PathHeight - 16, Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = $"{n.Title}: {n.Status}" };
        var label = new TextBlock
        {
            Text = n.Label, FontFamily = Mono, FontSize = 11, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, PathY - 50, 0, 0), VerticalAlignment = VerticalAlignment.Top,
        };
        col.Children.Add(label);

        var dial = new Canvas { Width = 80, Height = 80, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, PathY - 40, 0, 0) };
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

        var below = new StackPanel { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, PathY + 36, 0, 0) };
        var title = new TextBlock
        {
            Text = n.Title.ToUpper(), FontFamily = Mono, FontSize = 10.5, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = w - 8,
        };
        below.Children.Add(title);
        var status = new TextBlock
        {
            Text = n.Status.ToUpper(), FontFamily = Mono, FontSize = 9.5, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = w - 8, Margin = new Thickness(0, 2, 0, 0),
        };
        status.SetResourceReference(TextBlock.ForegroundProperty, n.State == Dot.Busy ? "Ob.Accent" : "Ob.Muted");
        below.Children.Add(status);
        col.Children.Add(below);

        col.MouseLeftButtonUp += (_, e) => { e.Handled = true; n.Open(); };
        Canvas.SetLeft(col, x - w / 2);
        Canvas.SetTop(col, 0);
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
