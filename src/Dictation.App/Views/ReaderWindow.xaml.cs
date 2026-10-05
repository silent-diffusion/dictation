using System.Windows;
using System.Windows.Automation;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Insertion;
using Dictation.Core.Reading;
using Dictation.Core.Setup;
using Dictation.Core.Speech;

namespace Dictation.App.Views;

/// <summary>
/// The Read aloud player: play/pause, ±15 s, slower/faster, time left, and the sentence being read with the spoken
/// part highlighted. Also asks before reading the clipboard and before the one-time voice download.
/// Like the dictation overlay it never takes keyboard focus, and it can be dragged anywhere.
/// </summary>
public partial class ReaderWindow : Window
{
    static readonly Brush Spoken = Freeze(new SolidColorBrush(Colors.White));
    static readonly Brush Current = Freeze(new SolidColorBrush(Color.FromRgb(0xF4, 0xA6, 0x8C)));
    static readonly Brush Upcoming = Freeze(new SolidColorBrush(Color.FromArgb(0x73, 0xFF, 0xFF, 0xFF)));
    const int WindowChars = 150; // longer sentences show a moving window around the spoken position
    const double CompactWidth = 520, ExpandedWidth = 640;

    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(100) };
    readonly DispatcherTimer _autoClose = new() { Interval = TimeSpan.FromSeconds(4) };
    ReadAloudSession? _session;
    CancellationTokenSource? _download;
    Func<Task>? _primary;
    (int Sentence, int Upto) _shown = (-1, -1);
    readonly WindowDrag _drag;
    string _voice = "af_heart"; // for the reading being started
    // Expanded view: one Span per sentence of the session it was built for; the current one holds three runs.
    readonly List<Span> _fullSentences = new();
    ReadAloudSession? _fullFor;
    int _fullCurrent = -1;

    public ReaderWindow()
    {
        InitializeComponent();
        _drag = new WindowDrag(this);
        ApplyExpanded();
        _tick.Tick += (_, _) => Refresh();
        _autoClose.Tick += (_, _) => { _autoClose.Stop(); if (!IsMouseOver) Stop(); };
        SizeChanged += (_, _) => Reposition();
    }

    static Brush Freeze(Brush b) { b.Freeze(); return b; }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var h = new WindowInteropHelper(this).Handle;
        var ex = Native.GetWindowLong(h, Native.GWL_EXSTYLE);
        Native.SetWindowLong(h, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
    }

    /// <summary>Reading, asking or downloading.</summary>
    public bool IsBusy => IsVisible;

    /// <summary>The position setting changed: forget where the player was dragged.</summary>
    public void ResetPosition() => _drag.Reset();

    void Reposition()
    {
        if (_drag.Place()) return; // the user dragged it somewhere
        var wa = SystemParameters.WorkArea;
        const double edge = 8;
        var settings = App.Services.Settings.Current;
        var pos = (int)(settings.ReaderPosition ?? settings.OverlayPosition);
        var (column, row) = (pos % 3, pos / 3);
        Left = column switch { 0 => wa.Left + edge, 1 => wa.Left + (wa.Width - ActualWidth) / 2, _ => wa.Right - ActualWidth - edge };
        Top = row switch { 0 => wa.Top + edge, 1 => wa.Top + (wa.Height - ActualHeight) / 2, _ => wa.Bottom - ActualHeight - edge };
    }

    void ShowWindow()
    {
        _autoClose.Stop();
        var opacity = Math.Clamp(App.Services.Settings.Current.ReaderOpacity, 0.3, 1.0);
        Card.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), 0x16, 0x16, 0x18));
        if (!IsVisible) Show();
        Reposition();
    }

    void ShowQuestion(string title, string body, string primary, Func<Task> onPrimary)
    {
        StopSession();
        Player.Visibility = Visibility.Collapsed;
        Question.Visibility = Visibility.Visible;
        QuestionButtons.Visibility = Visibility.Visible;
        DownloadProgress.Visibility = Visibility.Collapsed;
        QuestionTitle.Text = title;
        QuestionBody.Text = body;
        PrimaryButton.Content = primary;
        _primary = onPrimary;
        ShowWindow();
    }

    /// <summary>Nothing was selected: offer to read the clipboard instead.</summary>
    public void AskToReadClipboard(string clipboard)
    {
        clipboard = MarkdownText.ForReading(clipboard); // so the preview, word count and estimate match what is read
        var words = clipboard.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        var minutes = ReadAloudText.Estimate(clipboard.Length).TotalMinutes / App.Services.Settings.Current.TtsBaseSpeed;
        var preview = clipboard.Length > 200 ? clipboard[..200].TrimEnd() + "…" : clipboard;
        ShowQuestion("Nothing is selected. Read your clipboard?",
            $"“{preview.ReplaceLineEndings(" ")}”\n{words:N0} words · about {Math.Max(1, Math.Round(minutes)):0} min",
            "Read clipboard", () => { Read(clipboard); return Task.CompletedTask; });
    }

    /// <summary>Read <paramref name="text"/> aloud, installing the voice first if needed (after asking).</summary>
    /// <param name="voice">The voice to use; null = the active profile's (or Read aloud's own).</param>
    public void Read(string text, string? voice = null)
    {
        _voice = voice ?? App.VoiceFor(App.Services.Profiles.Active);
        if (!VoiceCatalog.IsWindowsVoice(_voice) && !RuntimeInstaller.ReadAloudInstalled)
        {
            ShowQuestion("Read aloud needs a one-time download",
                $"Oberton's voice (Kokoro) is about {RuntimeInstaller.ReadAloudDownloadMb} MB. It runs entirely on this PC, " +
                "so after this nothing you read leaves it.",
                "Download", () => DownloadThenReadAsync(text));
            return;
        }
        StartSession(text);
    }

    async Task DownloadThenReadAsync(string text)
    {
        QuestionButtons.Visibility = Visibility.Collapsed;
        DownloadProgress.Visibility = Visibility.Visible;
        QuestionTitle.Text = "Downloading the voice…";
        _download = new CancellationTokenSource();
        var progress = new Progress<SetupProgress>(p =>
        {
            QuestionBody.Text = p.Title + (p.Detail.Length > 0 ? " · " + p.Detail : "");
            DownloadFill.Width = (p.Fraction ?? 0) * DownloadProgress.ActualWidth;
        });
        try
        {
            await new RuntimeInstaller(App.Services.Settings, App.Services.OllamaHost).InstallReadAloudAsync(progress, _download.Token);
            StartSession(text);
        }
        catch (OperationCanceledException) { Hide(); }
        catch (UserFacingException e) { ShowError(e.Message); }
        catch (Exception e)
        {
            Log.Error("Read aloud install failed", e);
            ShowError("The voice download failed. See the log for details, and try again.");
        }
        finally { _download = null; }
    }

    void ShowError(string message) =>
        ShowQuestion("Read aloud couldn't start", message, "OK", () => { Stop(); return Task.CompletedTask; });

    void StartSession(string text)
    {
        StopSession();
        text = MarkdownText.ForReading(text); // read Markdown as the plain text it stands for
        var s = App.Services.Settings.Current;
        var session = new ReadAloudSession(text, App.Services.Voices, _voice, s.TtsBaseSpeed);
        if (session.Sentences.Count == 0)
        {
            ShowError("There's nothing to read in that text.");
            return;
        }
        App.Services.Usage.RecordReading(text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length);
        session.Finished += () => Dispatcher.BeginInvoke(OnFinished);
        session.Failed += message => Dispatcher.BeginInvoke(() => ShowError(message));
        _session = session;
        _shown = (-1, -1);
        Question.Visibility = Visibility.Collapsed;
        Player.Visibility = Visibility.Visible;
        ShowWindow();
        session.Start();
        _tick.Start();
        Refresh();
    }

    void OnFinished()
    {
        Refresh();
        _autoClose.Start(); // closes in a moment unless the pointer is on it (to replay or skip back)
    }

    void Refresh()
    {
        var s = _session;
        if (s == null) return;
        var ended = s.IsEnded;
        PlayGlyph.Text = ended || s.IsPaused ? "" : ""; // play : pause
        PlayButton.ToolTip = ended ? "Read again" : s.IsPaused ? "Play" : "Pause";
        SpeedText.Text = $"{s.Speed:0.0#}×"; // 1.65 stays 1.65, not 1.7
        SlowerButton.IsEnabled = s.Speed > ReadAloudSession.MinSpeed + 0.001;
        FasterButton.IsEnabled = s.Speed < ReadAloudSession.MaxSpeed - 0.001;
        var left = s.Remaining;
        RemainingText.Text = $"{(int)left.TotalMinutes}:{left.Seconds:00}";
        StatusText.Text = ended ? "Done" : s.IsPaused ? "Paused" : s.IsBuffering ? "Preparing voice…" : "left";
        ProgressFill.Width = s.Progress * Math.Max(0, ((FrameworkElement)ProgressFill.Parent).ActualWidth);
        ShowLines(s);
    }

    /// <summary>The current sentence: spoken words white, the word being spoken accented, the rest dimmed.
    /// Compact: that sentence only, at most two lines. Expanded: the whole text, scrolled to it.</summary>
    void ShowLines(ReadAloudSession s)
    {
        var (index, fraction) = s.Position;
        var span = s.Sentences[index];
        var sentence = s.Text.Substring(span.Start, span.Length).ReplaceLineEndings(" ");
        var upto = (int)Math.Round(fraction * sentence.Length);
        if (_shown == (index, upto)) return;
        _shown = (index, upto);

        // The word being spoken: from the last space before the position to the next space after it.
        var wordStart = upto <= 0 ? 0 : sentence.LastIndexOf(' ', Math.Min(upto, sentence.Length) - 1) + 1;
        var nextSpace = upto >= sentence.Length ? -1 : sentence.IndexOf(' ', upto);
        var wordEnd = nextSpace >= 0 ? nextSpace : sentence.Length;
        if (s.IsEnded) wordStart = wordEnd = sentence.Length;

        if (Settings.ReaderExpanded) { ShowFull(s, index, sentence, wordStart, wordEnd); return; }

        var from = 0;
        var to = sentence.Length;
        if (sentence.Length > WindowChars)
        {
            from = Math.Clamp(wordStart - WindowChars / 3, 0, sentence.Length - WindowChars);
            if (from > 0) from = sentence.IndexOf(' ', from) + 1;
            to = Math.Min(sentence.Length, from + WindowChars);
        }
        Lines.Inlines.Clear();
        if (from > 0) Lines.Inlines.Add(new Run("… ") { Foreground = Upcoming });
        Add(Lines.Inlines, sentence, from, Math.Min(wordStart, to), Spoken);
        Add(Lines.Inlines, sentence, Math.Max(from, wordStart), Math.Min(wordEnd, to), Current);
        Add(Lines.Inlines, sentence, Math.Max(from, wordEnd), to, Upcoming);
        if (to < sentence.Length) Lines.Inlines.Add(new Run(" …") { Foreground = Upcoming });
    }

    /// <summary>Expanded view: sentences before the current one in white, after it dimmed, the current one
    /// highlighted like the compact view and kept in view.</summary>
    void ShowFull(ReadAloudSession s, int index, string sentence, int wordStart, int wordEnd)
    {
        if (_fullFor != s) BuildFull(s);
        var moved = index != _fullCurrent;
        if (moved)
        {
            if (_fullCurrent >= 0 && _fullCurrent < _fullSentences.Count) // the previous sentence: back to one plain run
            {
                var prev = s.Sentences[_fullCurrent];
                _fullSentences[_fullCurrent].Inlines.Clear();
                _fullSentences[_fullCurrent].Inlines.Add(new Run(s.Text.Substring(prev.Start, prev.Length).ReplaceLineEndings(" ")));
            }
            for (var i = 0; i < _fullSentences.Count; i++)
                _fullSentences[i].Foreground = i < index ? Spoken : Upcoming;
            _fullCurrent = index;
        }
        var current = _fullSentences[index];
        current.Inlines.Clear();
        Add(current.Inlines, sentence, 0, wordStart, Spoken);
        Add(current.Inlines, sentence, wordStart, wordEnd, Current);
        Add(current.Inlines, sentence, wordEnd, sentence.Length, Upcoming);
        if (current.Inlines.Count == 0) current.Inlines.Add(new Run(sentence)); // keep the span, so it can be scrolled to
        if (moved) current.BringIntoView();
    }

    /// <summary>The whole text with the gaps between sentences (spaces, line breaks) kept as they are.</summary>
    void BuildFull(ReadAloudSession s)
    {
        FullText.Inlines.Clear();
        _fullSentences.Clear();
        var prev = 0;
        foreach (var span in s.Sentences)
        {
            if (span.Start > prev) FullText.Inlines.Add(new Run(s.Text[prev..span.Start].ReplaceLineEndings("\n")));
            var sp = new Span(new Run(s.Text.Substring(span.Start, span.Length).ReplaceLineEndings(" "))) { Foreground = Upcoming };
            _fullSentences.Add(sp);
            FullText.Inlines.Add(sp);
            prev = span.Start + span.Length;
        }
        _fullFor = s;
        _fullCurrent = -1;
        FullScroll.ScrollToTop();
    }

    static Dictation.Core.Settings.AppSettings Settings => App.Services.Settings.Current;

    void Expand_Click(object sender, RoutedEventArgs e)
    {
        Settings.ReaderExpanded = !Settings.ReaderExpanded;
        App.Services.Settings.Save();
        ApplyExpanded();
        _shown = (-1, -1); // redraw in the new view
        _fullFor = null;
        if (_session != null) Refresh();
    }

    void ApplyExpanded()
    {
        var expanded = Settings.ReaderExpanded;
        Lines.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
        FullScroll.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        Root.Width = expanded ? ExpandedWidth : CompactWidth;
        ExpandGlyph.Text = expanded ? "\uE70E" : "\uE70D"; // chevron up : down
        ExpandButton.ToolTip = expanded ? "Show the current sentence only" : "Show the whole text";
        AutomationProperties.SetName(ExpandButton, (string)ExpandButton.ToolTip);
    }

    static void Add(InlineCollection inlines, string text, int start, int end, Brush brush)
    {
        if (end > start) inlines.Add(new Run(text[start..end]) { Foreground = brush });
    }

    void StopSession()
    {
        _tick.Stop();
        _session?.Dispose();
        _session = null;
    }

    /// <summary>Stop reading (or cancel the question/download) and hide.</summary>
    public void Stop()
    {
        _download?.Cancel();
        StopSession();
        _autoClose.Stop();
        Hide();
    }

    void Play_Click(object sender, RoutedEventArgs e)
    {
        if (_session == null) return;
        _autoClose.Stop();
        if (_session.IsEnded) _session.Skip(-1e9); // read again from the start
        else _session.TogglePause();
        Refresh();
    }

    void Back_Click(object sender, RoutedEventArgs e) { _autoClose.Stop(); _session?.Skip(-15); Refresh(); }
    void Forward_Click(object sender, RoutedEventArgs e) { _session?.Skip(15); Refresh(); }
    void Slower_Click(object sender, RoutedEventArgs e) { _session?.SetSpeed(_session.Speed - ReadAloudSession.SpeedStep); Refresh(); }
    void Faster_Click(object sender, RoutedEventArgs e) { _session?.SetSpeed(_session.Speed + ReadAloudSession.SpeedStep); Refresh(); }
    void Close_Click(object sender, RoutedEventArgs e) => Stop();

    async void Primary_Click(object sender, RoutedEventArgs e)
    {
        var action = _primary;
        _primary = null;
        if (action != null) await action();
    }
}
