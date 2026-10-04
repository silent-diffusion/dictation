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
public partial class HistoryPage : UserControl
{
    readonly ListCollectionView _view;
    readonly MediaPlayer _player = new();
    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(200) };
    bool _playing, _seeking;

    public HistoryPage()
    {
        InitializeComponent();
        var store = App.Services.History;
        _view = new ListCollectionView(store.Entries);
        List.ItemsSource = _view;
        GroupingBox.SelectedIndex = App.Services.Settings.Current.HistoryGrouping == HistoryGrouping.ByApp ? 1 : 0;
        ApplyGrouping();
        store.Entries.CollectionChanged += OnEntriesChanged;
        _player.MediaEnded += (_, _) => StopPlayback();
        _player.MediaOpened += (_, _) => UpdateTime();
        _tick.Tick += (_, _) => UpdateTime();
        Unloaded += (_, _) =>
        {
            store.Entries.CollectionChanged -= OnEntriesChanged;
            _tick.Stop();
            _player.Close();
        };
        UpdateCount();
        if (_view.Count > 0) List.SelectedIndex = 0;
    }

    HistoryEntry? Current => List.SelectedItem as HistoryEntry;

    void OnEntriesChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        UpdateCount();
        if (List.SelectedItem == null && _view.Count > 0) List.SelectedIndex = 0;
    }

    void UpdateCount()
    {
        var s = App.Services.Settings.Current;
        var n = App.Services.History.Entries.Count;
        CountText.Text = !s.KeepHistory
            ? "History is off (Settings › History). Earlier dictations stay until you clear them."
            : $"{n} of the last {s.HistoryLimit} dictations, kept on this PC (they survive updates). Change how many under Settings › History.";
        EmptyText.Visibility = n == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void Grouping_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_view == null) return;
        var s = App.Services.Settings;
        s.Current.HistoryGrouping = GroupingBox.SelectedIndex == 1 ? HistoryGrouping.ByApp : HistoryGrouping.Chronological;
        s.Save();
        ApplyGrouping();
    }

    /// <summary>By app: groups ordered by their newest dictation, newest first inside each (the entries already are).</summary>
    void ApplyGrouping()
    {
        _view.GroupDescriptions.Clear();
        if (App.Services.Settings.Current.HistoryGrouping == HistoryGrouping.ByApp)
            _view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(HistoryEntry.AppName)));
    }

    void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        StopPlayback();
        _player.Close();
        var c = Current;
        Detail.Visibility = c == null ? Visibility.Collapsed : Visibility.Visible;
        Info.Text = "";
        if (c == null) return;

        TitleText.Text = $"{c.Time:dddd d MMMM}, {c.Time:t}";
        var where = c.WasInserted ? "Inserted into " + c.AppName : "Not inserted (meant for " + c.AppName + ")";
        if (c.WindowTitle.Length > 0) where += " · " + c.WindowTitle;
        WhereText.Text = $"{where}\nProfile: {c.Profile} · {c.Duration} of speech";

        var audio = c.HasAudio;
        Player.Visibility = audio ? Visibility.Visible : Visibility.Collapsed;
        NoAudioText.Visibility = audio ? Visibility.Collapsed : Visibility.Visible;
        if (audio) _player.Open(new Uri(c.AudioPath));
        Seek.Value = 0;
        UpdateTime();

        TranscriptBox.Text = c.Transcript;
        AiPanel.Visibility = c.AiOutput != null ? Visibility.Visible : Visibility.Collapsed;
        AiBox.Text = c.AiOutput ?? "";
        if (c.AiOutput != null)
            DiffText.Render(DiffBlock, WordDiff.Compute(c.Transcript, c.AiOutput),
                (Brush)FindResource("Ob.DiffRemoved"), (Brush)FindResource("Ob.DiffAdded"));
        FinalBox.Text = c.Final;
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

    void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (Current is not { } c) return;
        StopPlayback();
        _player.Close(); // release the audio file
        App.Services.History.Delete(c);
    }

    void CopyFinal_Click(object sender, RoutedEventArgs e) { if (Current != null) Clipboard.SetText(Current.Final); }
    void CopyRaw_Click(object sender, RoutedEventArgs e) { if (Current != null) Clipboard.SetText(Current.Transcript); }

    async void InsertRaw_Click(object sender, RoutedEventArgs e)
    {
        if (Current == null) return;
        try { await App.Services.Controller.InsertIntoLastTargetAsync(Current.Transcript); }
        catch (UserFacingException ex) { Info.Text = "⚠ " + ex.Message; }
    }
}
