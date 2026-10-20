using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;

namespace Dictation.App.Views;

/// <summary>
/// The dashboard's History cell, two meters wide at the right of the meters' row: how many dictations are kept (a big
/// number, like the meters'), the last dictation's AI edit (or, when the AI didn't edit it, what went in) with COPY, and
/// INSERT TRANSCRIPTION INTO THE LAST APP at the bottom (the words as they were heard, as on the History page), which
/// says where the text went. The text is in the meters' face, as large as fits the cell; when even the smallest size
/// doesn't fit, it scrolls. The title opens History. Built once and updated in place only when the last dictation
/// changes, so the 3-second refresh doesn't reset its scrolling.
/// </summary>
public partial class DashboardPage
{
    const double HistoryMinFont = 11, HistoryMaxFont = 30;

    TextBlock _historyCount = null!, _historyOf = null!, _historyMeta = null!, _historyText = null!, _historyKind = null!, _historyDone = null!;
    ScrollViewer _historyScroll = null!;
    Button _historyCopy = null!, _historyInsert = null!;
    HistoryEntry? _historyShown;
    string? _historyShownText;
    readonly DispatcherTimer _historyDoneTimer = new() { Interval = TimeSpan.FromSeconds(5) };

    void BuildHistoryCell()
    {
        var mono = (FontFamily)FindResource("Ob.Mono");
        var root = new DockPanel();

        // Header: HISTORY (opens the page) ... how many are kept, large
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 6), Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = "Open History" };
        var count = new StackPanel { VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(8, 0, 0, 0) };
        _historyCount = new TextBlock { FontFamily = mono, FontSize = 28, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Right };
        _historyCount.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        _historyOf = new TextBlock { Style = Readout, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Right };
        count.Children.Add(_historyCount);
        count.Children.Add(_historyOf);
        DockPanel.SetDock(count, Dock.Right);
        head.Children.Add(count);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Top };
        var title = new TextBlock { Text = "HISTORY", FontFamily = mono, FontSize = 13, FontWeight = FontWeights.Bold };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        titles.Children.Add(title);
        // What the text is, and where it went
        _historyKind = new TextBlock { Style = Readout, FontSize = 10, Margin = new Thickness(0, 6, 0, 0) };
        _historyMeta = new TextBlock { FontFamily = mono, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
        _historyMeta.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        titles.Children.Add(_historyKind);
        titles.Children.Add(_historyMeta);
        head.Children.Add(titles);
        AccentOnHover(head, wash: false, (title, TextBlock.ForegroundProperty, "Ob.Text"), (_historyCount, TextBlock.ForegroundProperty, "Ob.Text"));
        head.MouseLeftButtonUp += (_, e) => { e.Handled = true; TheApp.ShowPage("History"); };
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        // Bottom: COPY and the insert button, and where the text went
        var bottom = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        _historyInsert = new Button
        {
            Content = "INSERT TRANSCRIPTION INTO THE LAST APP", Style = (Style)FindResource("QuietButton"), FontSize = 10,
            Padding = new Thickness(12, 4, 12, 4),
            ToolTip = "Insert the last dictation's transcription (the words as heard) into the app it went to; this window stays in front",
        };
        _historyInsert.Click += async (_, _) => await InsertLastTranscriptionAsync();
        DockPanel.SetDock(_historyInsert, Dock.Left);
        bottom.Children.Add(_historyInsert);
        _historyCopy = new Button { Content = "COPY", Style = (Style)FindResource("QuietButton"), FontSize = 10, Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(8, 0, 0, 0), ToolTip = "Copy the text shown" };
        _historyCopy.Click += (_, _) => CopyShown();
        DockPanel.SetDock(_historyCopy, Dock.Left);
        bottom.Children.Add(_historyCopy);
        _historyDone = new TextBlock { FontFamily = mono, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis, Opacity = 0 };
        _historyDone.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Accent");
        bottom.Children.Add(_historyDone);
        _historyDoneTimer.Tick += (_, _) =>
        {
            _historyDoneTimer.Stop();
            _historyDone.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(400)));
        };
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(bottom);

        // The text itself: as large as fits, scrolling once the smallest size doesn't
        _historyText = new TextBlock { TextWrapping = TextWrapping.Wrap, FontFamily = mono, FontSize = 14 };
        _historyText.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        _historyScroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = _historyText };
        _historyScroll.SizeChanged += (_, e) => { if (e.WidthChanged || e.HeightChanged) FitHistoryText(); };
        root.Children.Add(_historyScroll);

        HistoryCell.Child = root;
    }

    /// <summary>Brought up to date by <see cref="Build"/>: the count every time, the text only when it changed.</summary>
    void UpdateHistoryCell(IReadOnlyList<HistoryEntry> entries, int limit)
    {
        _historyCount.Text = entries.Count.ToString("N0");
        _historyOf.Text = limit > 0 ? $"OF {limit:N0} KEPT" : "KEPT, NO LIMIT";
        var last = entries.OrderByDescending(x => x.Time).FirstOrDefault();
        var text = Shown(last);
        if (ReferenceEquals(last, _historyShown) && text == _historyShownText) return;
        _historyShown = last;
        _historyShownText = text;
        _historyCopy.IsEnabled = text.Length > 0;
        _historyInsert.IsEnabled = last is { Transcript.Length: > 0 };
        if (last == null)
        {
            _historyKind.Text = "LAST AI EDIT";
            _historyMeta.Text = "";
            _historyText.Text = "Nothing dictated yet. Your last dictation shows here.";
            _historyText.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        }
        else
        {
            _historyKind.Text = last.AiOutput is { Length: > 0 } ? "LAST AI EDIT" : "LAST DICTATION // NO AI EDIT";
            _historyMeta.Text = $"{last.AppName} · {last.When} · {last.Words:N0} word{(last.Words == 1 ? "" : "s")}";
            _historyText.Text = text;
            _historyText.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        }
        FitHistoryText();
        _historyScroll.ScrollToTop();
    }

    /// <summary>The largest size at which the whole text fits the cell (between the smallest and largest sizes);
    /// at the smallest, a longer text scrolls.</summary>
    void FitHistoryText()
    {
        var (w, h) = (_historyScroll.ActualWidth, _historyScroll.ActualHeight);
        if (w < 20 || h < 10) return;
        bool Fits(double size)
        {
            _historyText.FontSize = size;
            _historyText.LineHeight = size * 1.4;
            _historyText.Measure(new Size(w - 2, double.PositiveInfinity));
            return _historyText.DesiredSize.Height <= h;
        }
        double lo = HistoryMinFont, hi = HistoryMaxFont;
        if (!Fits(lo)) return; // the smallest size, scrolling
        if (Fits(hi)) return;
        while (hi - lo > 0.5)
        {
            var mid = (lo + hi) / 2;
            if (Fits(mid)) lo = mid; else hi = mid;
        }
        Fits(Math.Floor(lo * 2) / 2);
    }

    /// <summary>What the cell shows of a dictation: the AI's edit; without one, what went in (or what was heard).</summary>
    static string Shown(HistoryEntry? e) =>
        e == null ? "" : e.AiOutput is { Length: > 0 } ai ? ai : e.Final.Length > 0 ? e.Final : e.Transcript;

    void CopyShown()
    {
        var text = _historyShownText ?? "";
        if (text.Length == 0) { Flash(_historyCopy, "NOTHING YET"); return; }
        try { Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.ExternalException) { Flash(_historyCopy, "BUSY, TRY AGAIN"); return; }
        Flash(_historyCopy, "COPIED ✓");
    }

    static void Flash(Button button, string label)
    {
        button.Content = label;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += (_, _) => { timer.Stop(); button.Content = "COPY"; };
        timer.Start();
    }

    /// <summary>The note beside the buttons: where the text went, for a few seconds.</summary>
    void ShowHistoryDone(string message)
    {
        _historyDone.Text = message;
        _historyDone.ToolTip = message;
        _historyDone.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(150)));
        _historyDoneTimer.Stop();
        _historyDoneTimer.Start();
    }

    async Task InsertLastTranscriptionAsync()
    {
        if (_historyShown is not { Transcript.Length: > 0 } last) return;
        try { ShowHistoryDone("✓ INSERTED INTO " + (await App.Services.Controller.InsertIntoLastTargetAsync(last.Transcript)).ToUpperInvariant()); }
        catch (UserFacingException ex) { ShowToast(ex.Message); }
    }
}
