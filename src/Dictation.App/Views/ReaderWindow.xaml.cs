using System.Windows;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Insertion;
using Dictation.Core.Reading;
using Dictation.Core.Setup;

namespace Dictation.App.Views;

/// <summary>
/// The Read aloud player: play/pause, ±15 s, slower/faster, time left, and the sentence being read with the spoken
/// part highlighted. Also asks before reading the clipboard and before the one-time voice download.
/// Like the dictation overlay it never takes keyboard focus.
/// </summary>
public partial class ReaderWindow : Window
{
    static readonly Brush Spoken = Freeze(new SolidColorBrush(Colors.White));
    static readonly Brush Current = Freeze(new SolidColorBrush(Color.FromRgb(0xF4, 0xA6, 0x8C)));
    static readonly Brush Upcoming = Freeze(new SolidColorBrush(Color.FromArgb(0x73, 0xFF, 0xFF, 0xFF)));
    const int WindowChars = 150; // longer sentences show a moving window around the spoken position

    readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromMilliseconds(100) };
    readonly DispatcherTimer _autoClose = new() { Interval = TimeSpan.FromSeconds(4) };
    ReadAloudSession? _session;
    CancellationTokenSource? _download;
    Func<Task>? _primary;
    (int Sentence, int Upto) _shown = (-1, -1);

    public ReaderWindow()
    {
        InitializeComponent();
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

    void Reposition()
    {
        var wa = SystemParameters.WorkArea;
        const double edge = 8;
        var pos = (int)App.Services.Settings.Current.OverlayPosition;
        var (column, row) = (pos % 3, pos / 3);
        Left = column switch { 0 => wa.Left + edge, 1 => wa.Left + (wa.Width - ActualWidth) / 2, _ => wa.Right - ActualWidth - edge };
        Top = row switch { 0 => wa.Top + edge, 1 => wa.Top + (wa.Height - ActualHeight) / 2, _ => wa.Bottom - ActualHeight - edge };
    }

    void ShowWindow()
    {
        _autoClose.Stop();
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
        var words = clipboard.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        var minutes = ReadAloudText.Estimate(clipboard.Length).TotalMinutes / App.Services.Settings.Current.TtsBaseSpeed;
        var preview = clipboard.Length > 200 ? clipboard[..200].TrimEnd() + "…" : clipboard;
        ShowQuestion("Nothing is selected. Read your clipboard?",
            $"“{preview.ReplaceLineEndings(" ")}”\n{words:N0} words · about {Math.Max(1, Math.Round(minutes)):0} min",
            "Read clipboard", () => { Read(clipboard); return Task.CompletedTask; });
    }

    /// <summary>Read <paramref name="text"/> aloud, installing the voice first if needed (after asking).</summary>
    public void Read(string text)
    {
        if (!RuntimeInstaller.ReadAloudInstalled)
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
        var s = App.Services.Settings.Current;
        var session = new ReadAloudSession(text, App.Services.Tts, s.TtsVoice, s.TtsBaseSpeed);
        if (session.Sentences.Count == 0)
        {
            ShowError("There's nothing to read in that text.");
            return;
        }
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
        SpeedText.Text = $"{s.Speed:0.0}×";
        SlowerButton.IsEnabled = s.Speed > ReadAloudSession.MinSpeed + 0.001;
        FasterButton.IsEnabled = s.Speed < ReadAloudSession.MaxSpeed - 0.001;
        var left = s.Remaining;
        RemainingText.Text = $"{(int)left.TotalMinutes}:{left.Seconds:00}";
        StatusText.Text = ended ? "Done" : s.IsPaused ? "Paused" : s.IsBuffering ? "Preparing voice…" : "left";
        ProgressFill.Width = s.Progress * Math.Max(0, ((FrameworkElement)ProgressFill.Parent).ActualWidth);
        ShowLines(s);
    }

    /// <summary>The current sentence: spoken words white, the word being spoken accented, the rest dimmed.</summary>
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
        Add(sentence, from, Math.Min(wordStart, to), Spoken);
        Add(sentence, Math.Max(from, wordStart), Math.Min(wordEnd, to), Current);
        Add(sentence, Math.Max(from, wordEnd), to, Upcoming);
        if (to < sentence.Length) Lines.Inlines.Add(new Run(" …") { Foreground = Upcoming });
    }

    void Add(string text, int start, int end, Brush brush)
    {
        if (end > start) Lines.Inlines.Add(new Run(text[start..end]) { Foreground = brush });
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
