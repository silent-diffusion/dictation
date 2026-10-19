using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;

namespace Dictation.App.Views;

/// <summary>
/// The dashboard's History cell, two meters wide at the right of the meters' row: the last dictation's AI edit (or, when
/// the AI didn't edit it, what went in), with COPY beside it, and INSERT TRANSCRIPTION INTO THE LAST APP at the bottom
/// (the words as they were heard, as on the History page). The title opens History. Built once and updated in place
/// only when the last dictation changes, so the 3-second refresh doesn't reset its scrolling.
/// </summary>
public partial class DashboardPage
{
    TextBlock _historyCount = null!, _historyMeta = null!, _historyText = null!, _historyKind = null!;
    ScrollViewer _historyScroll = null!;
    Button _historyCopy = null!, _historyInsert = null!;
    HistoryEntry? _historyShown;
    string? _historyShownText;

    void BuildHistoryCell()
    {
        var mono = (FontFamily)FindResource("Ob.Mono");
        var root = new DockPanel();

        // Header: HISTORY (opens the page) ... how many are kept
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 6), Background = Brushes.Transparent, Cursor = Cursors.Hand, ToolTip = "Open History" };
        _historyCount = new TextBlock { Style = Readout, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        DockPanel.SetDock(_historyCount, Dock.Right);
        head.Children.Add(_historyCount);
        var title = new TextBlock { Text = "HISTORY", FontFamily = mono, FontSize = 13, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center };
        title.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        head.Children.Add(title);
        AccentOnHover(head, wash: false, (title, TextBlock.ForegroundProperty, "Ob.Text"));
        head.MouseLeftButtonUp += (_, e) => { e.Handled = true; TheApp.ShowPage("History"); };
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        // Bottom: the insert button
        _historyInsert = new Button
        {
            Content = "INSERT TRANSCRIPTION INTO THE LAST APP", Style = (Style)FindResource("QuietButton"), FontSize = 10,
            Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left,
            ToolTip = "Insert the last dictation's transcription (the words as heard) into the app it went to",
        };
        _historyInsert.Click += async (_, _) => await InsertLastTranscriptionAsync();
        DockPanel.SetDock(_historyInsert, Dock.Bottom);
        root.Children.Add(_historyInsert);

        // What the text is, where it went, and COPY
        var line = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        _historyCopy = new Button { Content = "COPY", Style = (Style)FindResource("QuietButton"), FontSize = 10, Padding = new Thickness(10, 2, 10, 2),
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        _historyCopy.Click += (_, _) => CopyShown();
        DockPanel.SetDock(_historyCopy, Dock.Right);
        line.Children.Add(_historyCopy);
        var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _historyKind = new TextBlock { Style = Readout, FontSize = 10 };
        _historyMeta = new TextBlock { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
        _historyMeta.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        labels.Children.Add(_historyKind);
        labels.Children.Add(_historyMeta);
        line.Children.Add(labels);
        DockPanel.SetDock(line, Dock.Top);
        root.Children.Add(line);

        // The text itself, scrolling when long
        _historyText = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12.5, LineHeight = 19 };
        _historyText.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
        _historyScroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = _historyText };
        root.Children.Add(_historyScroll);

        HistoryCell.Child = root;
    }

    /// <summary>Brought up to date by <see cref="Build"/>: the count every time, the text only when it changed.</summary>
    void UpdateHistoryCell(IReadOnlyList<HistoryEntry> entries, int limit)
    {
        _historyCount.Text = limit > 0 ? $"{entries.Count} OF {limit} KEPT" : $"{entries.Count} KEPT";
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
        _historyScroll.ScrollToTop();
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

    async Task InsertLastTranscriptionAsync()
    {
        if (_historyShown is not { Transcript.Length: > 0 } last) return;
        try { await App.Services.Controller.InsertIntoLastTargetAsync(last.Transcript); }
        catch (UserFacingException ex) { ShowToast(ex.Message); }
    }
}
