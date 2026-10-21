using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;
using Dictation.Core.Settings;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// Recent dictations, kept on disk: the recording (playable, also at 2×), what was heard, what the AI made of it (and
/// what it changed), and what went in where. Newest first, or grouped by the app the text went into.
/// </summary>
/// <summary>An app's header in History's list by app: a row of its own, clicked to fold or unfold the app.</summary>
public sealed record HistoryAppHeader(string Name, int Count, bool Expanded)
{
    public string Sign => Expanded ? "−" : "+";
}

public partial class HistoryPage : UserControl
{
    /// <summary>What the list shows: the dictations, newest first, or by app (a header, then that app's dictations).</summary>
    List<object> _rows = new();
    /// <summary>Apps folded in the list by app (for as long as the page is open).</summary>
    readonly HashSet<string> _folded = new(StringComparer.OrdinalIgnoreCase);
    bool _rebuilding;
    readonly MediaPlayer _player = new();
    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(200) };
    bool _playing, _seeking;
    string? _playCopy; // the player reads a temporary copy, so the entry's own file is never locked

    public HistoryPage()
    {
        InitializeComponent();
        var store = App.Services.History;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        _rebuilding = true; // the combo box's first selection isn't a change of setting
        GroupingBox.SelectedIndex = App.Services.Settings.Current.HistoryGrouping == HistoryGrouping.ByApp ? 1 : 0;
        _rebuilding = false;
        store.Entries.CollectionChanged += OnEntriesChanged;
        _player.MediaEnded += (_, _) => StopPlayback();
        _player.MediaOpened += (_, _) => UpdateTime();
        _tick.Tick += (_, _) => UpdateTime();
        Unloaded += (_, _) =>
        {
            store.Entries.CollectionChanged -= OnEntriesChanged;
            _tick.Stop();
            ClosePlayer();
        };
        UpdateCount();
        Rebuild(null);
        if (clock.ElapsedMilliseconds >= 100) Log.Info($"History page: built in {clock.ElapsedMilliseconds} ms ({store.Entries.Count} dictations)");
    }

    HistoryEntry? Current => List.SelectedItem as HistoryEntry;

    void OnEntriesChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        UpdateCount();
        Rebuild(Current);
    }

    /// <summary>Lay out the rows again (after a change, a fold, or a new order), keeping <paramref name="keep"/> selected
    /// if it is still shown, else the first dictation.</summary>
    void Rebuild(HistoryEntry? keep)
    {
        var entries = App.Services.History.Entries;
        var rows = new List<object>(entries.Count + 32);
        if (App.Services.Settings.Current.HistoryGrouping == HistoryGrouping.ByApp)
        {
            // Apps in the order of their newest dictation (the entries are newest first), newest first inside each.
            foreach (var app in entries.GroupBy(e => e.AppName, StringComparer.OrdinalIgnoreCase))
            {
                var open = !_folded.Contains(app.Key);
                var list = app.ToList();
                rows.Add(new HistoryAppHeader(app.Key, list.Count, open));
                if (open) rows.AddRange(list);
            }
        }
        else rows.AddRange(entries);
        _rows = rows;
        var select = keep != null && rows.Contains(keep) ? keep : rows.OfType<HistoryEntry>().FirstOrDefault();
        _rebuilding = true;
        List.ItemsSource = rows;
        List.SelectedItem = select;
        _rebuilding = false;
        if (select != null) List.ScrollIntoView(select);
        ShowDetail();
    }

    /// <summary>A click on an app's header folds or unfolds it.</summary>
    void Header_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not HistoryAppHeader h) return;
        if (!_folded.Remove(h.Name)) _folded.Add(h.Name);
        Rebuild(Current);
    }

    void UpdateCount()
    {
        var s = App.Services.Settings.Current;
        var n = App.Services.History.Entries.Count;
        CountText.Text = !s.KeepHistory
            ? "History is off (Settings › History). Earlier dictations stay until you clear them."
            : s.HistoryLimit > 0 ? $"{n} of the last {s.HistoryLimit} dictations, kept on this PC (they survive updates). Change how many under Settings › History."
            : s.HistoryDays > 0 ? $"{n} dictations from the last {HistoryStore.DaysLabel(s.HistoryDays)}, kept on this PC (they survive updates). Change how long under Settings › History."
            : $"{n} dictations, all kept on this PC (they survive updates). Change this under Settings › History.";
        EmptyText.Visibility = n == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void Grouping_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_rebuilding) return;
        var s = App.Services.Settings;
        s.Current.HistoryGrouping = GroupingBox.SelectedIndex == 1 ? HistoryGrouping.ByApp : HistoryGrouping.Chronological;
        s.Save();
        Rebuild(Current);
    }

    HistoryEntry? _shown;

    void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_rebuilding) return;
        if (List.SelectedItem is HistoryAppHeader)
        {
            // Arrowed onto a header: go on to the next dictation the way the arrow was going.
            var at = List.SelectedIndex;
            var from = _shown != null ? _rows.IndexOf(_shown) : -1;
            var step = from > at ? -1 : 1;
            var i = at;
            while (i >= 0 && i < _rows.Count && _rows[i] is not HistoryEntry) i += step;
            if (i < 0 || i >= _rows.Count) { i = at; while (i >= 0 && i < _rows.Count && _rows[i] is not HistoryEntry) i -= step; }
            List.SelectedItem = i >= 0 && i < _rows.Count ? _rows[i] : _shown;
            if (List.SelectedItem != null) List.ScrollIntoView(List.SelectedItem);
            return;
        }
        if (ReferenceEquals(Current, _shown) && Current != null) return;
        ShowDetail();
    }

    /// <summary>The selected dictation in full, on the right.</summary>
    void ShowDetail()
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        try { ShowDetailNow(); }
        finally { if (clock.ElapsedMilliseconds >= 100) Log.Info($"History page: showing a dictation took {clock.ElapsedMilliseconds} ms"); }
    }

    void ShowDetailNow()
    {
        _shown = Current;
        StopPlayback();
        ClosePlayer();
        var c = Current;
        Detail.Visibility = c == null ? Visibility.Collapsed : Visibility.Visible;
        Info.Text = "";
        if (c == null) return;

        TitleText.Text = $"{c.Time:dddd d MMMM}, {c.Time:t}";
        RunAgainButton.Visibility = c.HasAudio ? Visibility.Visible : Visibility.Collapsed;
        RunAgainButton.IsEnabled = !_rerunning;
        RerunRow.Visibility = c.RunAgainAt != null && c.Earlier != null ? Visibility.Visible : Visibility.Collapsed;
        if (c.RunAgainAt is { } at)
        {
            RerunText.Text = c.ShowingEarlier ? $"Run again {at:d MMM}, {at:t}; showing the result from before"
                                              : $"Run again {at:d MMM}, {at:t}";
            SwapButton.Content = c.ShowingEarlier ? "USE THE RERUN" : "PUT BACK THE EARLIER RESULT";
            SwapButton.SetResourceReference(ForegroundProperty, "Ob.Accent");
        }
        var where = c.WasInserted ? "Inserted into " + c.AppName : "Not inserted (meant for " + c.AppName + ")";
        if (c.WindowTitle.Length > 0) where += " · " + c.WindowTitle;
        WhereText.Text = $"{where}\nProfile: {c.Profile} · {c.Duration} of speech";

        var audio = c.HasAudio;
        Player.Visibility = audio ? Visibility.Visible : Visibility.Collapsed;
        NoAudioText.Visibility = audio ? Visibility.Collapsed : Visibility.Visible;
        if (audio)
        {
            try
            {
                _playCopy = Path.Combine(Path.GetTempPath(), $"oberton-play-{Guid.NewGuid():N}.wav");
                File.Copy(c.AudioPath, _playCopy);
                _player.Open(new Uri(_playCopy));
            }
            catch (Exception ex)
            {
                Log.Warn("Couldn't open a recording: " + ex.Message);
                Player.Visibility = Visibility.Collapsed;
                NoAudioText.Visibility = Visibility.Visible;
            }
        }
        Seek.Value = 0;
        UpdateTime();

        TranscriptBlock.Text = c.Transcript;
        if (c.AiOutput != null)
        {
            DiffBlock.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            DiffText.Render(DiffBlock, WordDiff.Compute(c.Transcript, c.AiOutput),
                (Brush)FindResource("Ob.DiffRemoved"), (Brush)FindResource("Ob.DiffAdded"));
        }
        else
        {
            DiffBlock.Inlines.Clear();
            DiffBlock.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            DiffBlock.Text = c.SafetyNet ? "The safety net rejected the AI's edit, so your words went in as spoken."
                : "No AI edit for this dictation.";
        }
        FinalBlock.Text = c.Final;
        CopyAiButton.IsEnabled = !string.IsNullOrEmpty(c.AiOutput); // nothing to copy when no AI edit was used
        CopyAiButton.Opacity = CopyAiButton.IsEnabled ? 1 : 0.35;    // a bare text link doesn't grey out by itself
        NoteText.Text = c.Note ?? (c.SafetyNet ? "The safety net kept some of your original words." : "");
    }

    void Play_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { HasAudio: true }) return;
        if (_playing) { _player.Pause(); _playing = false; _tick.Stop(); }
        else
        {
            _player.SpeedRatio = SpeedButton.IsChecked == true ? 2.0 : 1.0;
            _player.Play();
            _playing = true;
            _tick.Start();
        }
        PlayGlyph.Text = _playing ? "" : ""; // pause : play
    }

    void Speed_Click(object sender, RoutedEventArgs e)
    {
        // The player keeps the pitch at 2×, so speech stays understandable.
        _player.SpeedRatio = SpeedButton.IsChecked == true ? 2.0 : 1.0;
    }

    /// <summary>Close the player and delete its temporary copy (the player may hold it a moment longer, so later too).</summary>
    void ClosePlayer()
    {
        _player.Close();
        var copy = _playCopy;
        _playCopy = null;
        if (copy == null) return;
        void TryDelete() { try { if (File.Exists(copy)) File.Delete(copy); } catch { } }
        TryDelete();
        Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, (Action)TryDelete);
    }

    void StopPlayback()
    {
        _player.Stop();
        _playing = false;
        _tick.Stop();
        PlayGlyph.Text = "";
        UpdateTime();
    }

    void UpdateTime()
    {
        var total = _player.NaturalDuration.HasTimeSpan ? _player.NaturalDuration.TimeSpan : TimeSpan.FromSeconds(Current?.Seconds ?? 0);
        var pos = _player.Position;
        TimeText.Text = $"{(int)pos.TotalMinutes}:{pos.Seconds:00} / {(int)total.TotalMinutes}:{total.Seconds:00}";
        _seeking = true;
        Seek.Value = total.TotalSeconds > 0 ? Math.Clamp(pos.TotalSeconds / total.TotalSeconds, 0, 1) : 0;
        _seeking = false;
    }

    void Seek_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_seeking || !_player.NaturalDuration.HasTimeSpan) return;
        _player.Position = TimeSpan.FromSeconds(e.NewValue * _player.NaturalDuration.TimeSpan.TotalSeconds);
        UpdateTime();
    }

    bool _rerunning;

    /// <summary>Run the shown dictation again from its recording (see <see cref="HistoryRerun"/>).</summary>
    async void RunAgain_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } c || _rerunning) return;
        _rerunning = true;
        RunAgainButton.IsEnabled = false;
        RunAgainButton.Content = "RUNNING…";
        var progress = new Progress<string>(m => { if (ReferenceEquals(Current, c)) Info.Text = m; });
        string message;
        try { message = "✓ " + await App.Services.Rerun.RunAsync(c, progress); }
        catch (UserFacingException ex) { message = "⚠ " + ex.Message; }
        catch (Exception ex)
        {
            Log.Error("History: running a dictation again failed", ex);
            message = "⚠ Running it again failed; the dictation was left as it was. See the log for details.";
        }
        finally
        {
            _rerunning = false;
            RunAgainButton.Content = "RUN AGAIN";
        }
        Rebuild(c);
        Info.Text = message;
    }

    void Swap_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } c) return;
        App.Services.Rerun.SwapEarlier(c);
        Rebuild(c);
        Info.Text = c.ShowingEarlier ? "Put back the result from before it was run again." : "Back to the rerun's result.";
    }

    void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } c) return;
        StopPlayback();
        ClosePlayer();
        App.Services.History.Delete(c);
    }

    void CopyFinal_Click(object sender, RoutedEventArgs e) => Copy((Button)sender, Current?.Final);
    void CopyRaw_Click(object sender, RoutedEventArgs e) => Copy((Button)sender, Current?.Transcript);
    void CopyAi_Click(object sender, RoutedEventArgs e) => Copy((Button)sender, Current?.AiOutput);

    /// <summary>Each box's COPY: copies that box and confirms in place, like the profile page's Try it.</summary>
    static void Copy(Button button, string? text)
    {
        if (string.IsNullOrEmpty(text)) { Flash(button, "NOTHING YET"); return; }
        try { Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.ExternalException) { Flash(button, "BUSY, TRY AGAIN"); return; }
        Flash(button, "COPIED ✓");
    }

    static void Flash(Button button, string label)
    {
        button.Content = label;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        timer.Tick += (_, _) => { timer.Stop(); button.Content = "COPY"; };
        timer.Start();
    }

    async void InsertRaw_Click(object sender, RoutedEventArgs e)
    {
        if (Current == null) return;
        try { Info.Text = "✓ Inserted into " + await App.Services.Controller.InsertIntoLastTargetAsync(Current.Transcript) + "."; }
        catch (UserFacingException ex) { Info.Text = "⚠ " + ex.Message; }
    }
}
