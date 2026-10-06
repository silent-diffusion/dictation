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
    MarkdownDoc? _doc; // the reading's text with its formatting (headings, lists, bold, links…)

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
        if (!VoiceCatalog.IsInstalled(_voice))
        {
            switch (VoiceCatalog.ModelOf(_voice))
            {
                case VoiceCatalog.Windows:
                    ShowError($"The Windows voice \"{VoiceCatalog.ShortName(_voice)}\" isn't installed on this PC any more. Pick another voice under Read aloud.");
                    return;
                case VoiceCatalog.Piper:
                    var piper = VoiceCatalog.FindPiper(_voice);
                    if (piper == null) { ShowError("That voice isn't available. Pick another voice under Read aloud."); return; }
                    ShowQuestion($"The voice {piper.Label} needs a one-time download",
                        $"It's a Piper voice of about {piper.Mb} MB. It runs entirely on this PC, so after this nothing you read leaves it.",
                        "Download", () => DownloadThenReadAsync(text));
                    return;
            }
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
            var installer = new RuntimeInstaller(App.Services.Settings, App.Services.OllamaHost);
            if (VoiceCatalog.FindPiper(_voice) is { } piper) await installer.InstallPiperVoiceAsync(piper, progress, _download.Token);
            else await installer.InstallReadAloudAsync(progress, _download.Token);
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
        // Markdown is read as the plain text it stands for; the whole-text view shows it formatted.
        _doc = MarkdownDoc.Parse(text);
        text = _doc.Plain;
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

    /// <summary>Expanded view: the whole text, formatted (headings, bullets, numbered items, quotes, code, bold, italic,
    /// links). Sentences before the current one in white, after it dimmed, the current one highlighted like the compact
    /// view and kept in view.</summary>
    void ShowFull(ReadAloudSession s, int index, string sentence, int wordStart, int wordEnd)
    {
        if (_fullFor != s) BuildFull(s);
        var moved = index != _fullCurrent;
        if (moved)
        {
            if (_fullCurrent >= 0 && _fullCurrent < _fullSentences.Count) // the previous sentence: back to its own colour
            {
                var prev = s.Sentences[_fullCurrent];
                _fullSentences[_fullCurrent].Inlines.Clear();
                AddFormatted(_fullSentences[_fullCurrent].Inlines, prev.Start, prev.Start + prev.Length, _ => null);
            }
            for (var i = 0; i < _fullSentences.Count; i++)
                _fullSentences[i].Foreground = i < index ? Spoken : Upcoming;
            _fullCurrent = index;
        }
        var span = s.Sentences[index];
        var current = _fullSentences[index];
        current.Inlines.Clear();
        AddFormatted(current.Inlines, span.Start, span.Start + span.Length, pos =>
            pos - span.Start < wordStart ? Spoken : pos - span.Start < wordEnd ? Current : Upcoming);
        if (current.Inlines.Count == 0) current.Inlines.Add(new Run(sentence)); // keep the span, so it can be scrolled to
        if (moved) current.BringIntoView();
    }

    /// <summary>The whole text, line by line with its formatting; each sentence is a span the highlight can colour.</summary>
    void BuildFull(ReadAloudSession s)
    {
        FullText.Inlines.Clear();
        _fullSentences.Clear();
        var doc = _doc ?? MarkdownDoc.Parse(s.Text);
        var sentences = s.Sentences;
        var next = 0; // the first sentence not placed yet
        for (var li = 0; li < doc.Lines.Count; li++)
        {
            var line = doc.Lines[li];
            if (li > 0)
            {
                FullText.Inlines.Add(new LineBreak());
                if (line.Kind == MdLineKind.Heading && doc.Lines[li - 1].Length > 0) FullText.Inlines.Add(new LineBreak()); // room above a heading
            }
            var prefix = line.Kind switch
            {
                MdLineKind.Bullet => new string(' ', 4 * line.Level) + "  •  ",
                MdLineKind.Numbered => new string(' ', 4 * line.Level) + "  ",
                MdLineKind.Quote => "▍ ",
                _ => "",
            };
            if (prefix.Length > 0) FullText.Inlines.Add(new Run(prefix) { Foreground = Upcoming });

            var pos = line.Start;
            var end = line.Start + line.Length;
            while (next < sentences.Count && sentences[next].Start < end)
            {
                var sentence = sentences[next];
                if (sentence.Start > pos) AddFormatted(FullText.Inlines, pos, sentence.Start, _ => null); // the gap before it
                var sp = new Span { Foreground = Upcoming };
                AddFormatted(sp.Inlines, sentence.Start, sentence.Start + sentence.Length, _ => null);
                _fullSentences.Add(sp);
                FullText.Inlines.Add(sp);
                pos = sentence.Start + sentence.Length;
                next++;
            }
            if (end > pos) AddFormatted(FullText.Inlines, pos, end, _ => null);
        }
        while (_fullSentences.Count < sentences.Count) // never expected (sentences stay within lines), but keep indexes valid
        {
            var sp = new Span { Foreground = Upcoming };
            _fullSentences.Add(sp);
            FullText.Inlines.Add(sp);
        }
        _fullFor = s;
        _fullCurrent = -1;
        FullScroll.ScrollToTop();
    }

    /// <summary>Runs for [from, to) of the plain text, split wherever the formatting or the colour changes.</summary>
    void AddFormatted(InlineCollection target, int from, int to, Func<int, Brush?> colourAt)
    {
        var doc = _doc;
        var text = _session?.Text ?? doc?.Plain ?? "";
        to = Math.Min(to, text.Length);
        var i = from;
        while (i < to)
        {
            var line = doc?.LineAt(i);
            var style = doc?.StyleAt(i) ?? MdStyle.None;
            var colour = colourAt(i);
            var j = i + 1;
            while (j < to && text[j] != '\n' && (doc?.StyleAt(j) ?? MdStyle.None) == style && colourAt(j) == colour) j++;
            var run = new Run(text[i..j].Replace('\n', ' '));
            if (colour != null) run.Foreground = colour;
            Format(run, style, line);
            target.Add(run);
            i = j;
        }
    }

    static readonly FontFamily Mono = new("Cascadia Mono, Consolas");
    static readonly Brush CodeBack = Freeze(new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)));

    static void Format(Run run, MdStyle style, MdLine? line)
    {
        switch (line?.Kind)
        {
            case MdLineKind.Heading:
                run.FontWeight = FontWeights.SemiBold;
                run.FontSize = line!.Level switch { 1 => 21, 2 => 18.5, 3 => 16.5, _ => 15.5 };
                break;
            case MdLineKind.Code:
                run.FontFamily = Mono;
                run.FontSize = 13.5;
                break;
            case MdLineKind.Quote:
                run.FontStyle = FontStyles.Italic;
                break;
        }
        if (style.HasFlag(MdStyle.Bold)) run.FontWeight = FontWeights.Bold;
        if (style.HasFlag(MdStyle.Italic)) run.FontStyle = FontStyles.Italic;
        if (style.HasFlag(MdStyle.Code)) { run.FontFamily = Mono; run.Background = CodeBack; }
        if (style.HasFlag(MdStyle.Link)) run.TextDecorations = TextDecorations.Underline;
        if (style.HasFlag(MdStyle.Strike)) run.TextDecorations = TextDecorations.Strikethrough;
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
    void Slower_Click(object sender, RoutedEventArgs e) => ChangeSpeed(-ReadAloudSession.SpeedStep);
    void Faster_Click(object sender, RoutedEventArgs e) => ChangeSpeed(ReadAloudSession.SpeedStep);

    /// <summary>The − and + buttons: the new speed is also remembered as the speed every reading starts at.</summary>
    void ChangeSpeed(double step)
    {
        if (_session == null) return;
        _session.SetSpeed(_session.Speed + step);
        App.Services.Settings.Current.TtsBaseSpeed = _session.Speed;
        App.Services.Settings.Save();
        Refresh();
    }
    void Close_Click(object sender, RoutedEventArgs e) => Stop();

    async void Primary_Click(object sender, RoutedEventArgs e)
    {
        var action = _primary;
        _primary = null;
        if (action != null) await action();
    }
}
