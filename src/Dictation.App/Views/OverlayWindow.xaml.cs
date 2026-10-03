using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Dictation.Core.Insertion;
using Dictation.Core.Session;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// The pill at the bottom center of the screen. Small while you talk; it grows only when it has text to show
/// (the cleanup, a preview, a receipt, a message). It is created with WS_EX_NOACTIVATE so it can never take
/// keyboard focus away from the application being dictated into.
/// </summary>
public partial class OverlayWindow : Window
{
    const double CompactWidth = 440, WideWidth = 470, NarrowWidth = 360;
    const int WaveBars = 30;

    static readonly Brush Muted = Freeze(new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)));
    static readonly Brush DiffRemoved = Freeze(new SolidColorBrush(Color.FromArgb(0x70, 0xFF, 0xFF, 0xFF)));
    static readonly Brush DiffAdded = Freeze(new SolidColorBrush(Color.FromRgb(0xF4, 0xA6, 0x8C)));
    static readonly Brush ErrorStroke = Freeze(new SolidColorBrush(Color.FromRgb(0xF9, 0x70, 0x66)));
    static readonly Brush WarnStroke = Freeze(new SolidColorBrush(Color.FromRgb(0xF4, 0xA6, 0x8C)));
    static readonly Brush RecordFill = Freeze(new SolidColorBrush(Color.FromRgb(0xE5, 0x53, 0x3A)));
    static readonly FontFamily Mono = new("Cascadia Mono, Consolas");
    static readonly FontFamily Ui = new("Segoe UI Variable Text, Segoe UI");

    readonly DispatcherTimer _hideTimer = new();
    readonly DispatcherTimer _clockTimer = new() { Interval = TimeSpan.FromMilliseconds(200) };
    readonly Stopwatch _recordClock = new();
    readonly double[] _levels = new double[WaveBars];
    DictationState _state = DictationState.Idle;
    string _hotkey = "";
    bool _pinnedByState, _previewShown;

    public event Action? CancelRequested;
    public event Action? InsertRequested;
    public event Action? InsertRawRequested;

    public OverlayWindow()
    {
        InitializeComponent();
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); if (!_pinnedByState) Hide(); };
        _clockTimer.Tick += (_, _) => TitleText.Text = FormatClock(_recordClock.Elapsed);
        SizeChanged += (_, _) => Reposition();
        for (var i = 0; i < WaveBars; i++)
            Wave.Children.Add(new Rectangle
            {
                Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Margin = new Thickness(0, 0, 3, 0),
                Fill = Brushes.White, Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center,
            });
    }

    static Brush Freeze(Brush b) { b.Freeze(); return b; }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var h = new WindowInteropHelper(this).Handle;
        var ex = Native.GetWindowLong(h, Native.GWL_EXSTYLE);
        Native.SetWindowLong(h, Native.GWL_EXSTYLE, ex | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW);
    }

    public void SetHotkeyText(string hotkey) => _hotkey = hotkey;

    void Reposition()
    {
        var wa = SystemParameters.WorkArea; // DIPs, primary monitor
        Left = wa.Left + (wa.Width - ActualWidth) / 2;
        Top = wa.Bottom - ActualHeight - 8; // the window's 16 px shadow margin puts the pill ~24 px above the taskbar
    }

    void Display(double width, bool expanded)
    {
        Body.Width = width;
        Card.CornerRadius = new CornerRadius(expanded ? 20 : 28);
        var opacity = Math.Clamp(App.Services.Settings.Current.OverlayOpacity, 0.6, 1.0);
        Card.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), 0x16, 0x16, 0x18));
        _hideTimer.Stop();
        if (!IsVisible) Show();
        Reposition();
    }

    void HideAfter(TimeSpan delay)
    {
        _hideTimer.Interval = delay;
        _hideTimer.Start();
    }

    /// <summary>Back to a blank pill: no indicator, no extras, plain white title.</summary>
    void ResetView()
    {
        _clockTimer.Stop();
        RecDot.BeginAnimation(OpacityProperty, null);
        SpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, null);
        Indicator.Visibility = Visibility.Visible;
        RecDot.Visibility = Spinner.Visibility = CheckIcon.Visibility = WarnIcon.Visibility = Visibility.Collapsed;
        RecDot.Opacity = 1;
        RecDot.Fill = RecordFill;
        Wave.Visibility = Dots.Visibility = Chip.Visibility = CancelButton.Visibility = Visibility.Collapsed;
        BodyText.Visibility = Actions.Visibility = Visibility.Collapsed;
        BodyText.Foreground = Brushes.White;
        BodyText.Inlines.Clear();
        TitleText.Inlines.Clear();
        TitleText.FontFamily = Ui;
        TitleText.FontWeight = FontWeights.SemiBold;
        SubtitleText.Text = "";
    }

    void ShowSpinner()
    {
        Spinner.Visibility = Visibility.Visible;
        SpinnerRotation.BeginAnimation(RotateTransform.AngleProperty,
            new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever });
    }

    void ShowChip(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        ChipText.Text = text;
        Chip.Visibility = Visibility.Visible;
    }

    void ShowBody(string text)
    {
        BodyText.Text = Tail(text, 260);
        BodyText.Visibility = Visibility.Visible;
    }

    void ShowDiff(string raw, string edited)
    {
        DiffText.Render(BodyText, WordDiff.Compute(raw, edited), DiffRemoved, DiffAdded, maxWords: 60);
        BodyText.Visibility = Visibility.Visible;
    }

    /// <param name="raw">The transcript being cleaned up or previewed.</param>
    /// <param name="preview">The cleaned-up text waiting for confirmation.</param>
    /// <param name="model">The AI model doing the cleanup.</param>
    public void ShowState(DictationState state, string profileName, string raw = "", string preview = "", string model = "")
    {
        _state = state;
        _pinnedByState = state != DictationState.Idle;
        if (state == DictationState.Idle)
        {
            _clockTimer.Stop();
            HideAfter(TimeSpan.FromMilliseconds(250));
            return;
        }

        ResetView();
        var width = CompactWidth;
        var expanded = false;
        switch (state)
        {
            case DictationState.Starting:
                ShowSpinner();
                TitleText.Text = "Starting";
                ShowChip(profileName);
                break;

            case DictationState.Recording:
                _previewShown = false;
                RecDot.Visibility = Visibility.Visible;
                RecDot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.35, TimeSpan.FromMilliseconds(700))
                    { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
                TitleText.FontFamily = Mono;
                TitleText.FontWeight = FontWeights.Normal;
                _recordClock.Restart();
                TitleText.Text = FormatClock(TimeSpan.Zero);
                _clockTimer.Start();
                Array.Clear(_levels);
                DrawWave();
                Wave.Visibility = Visibility.Visible;
                ShowChip(profileName);
                CancelButton.Visibility = Visibility.Visible;
                break;

            case DictationState.Transcribing:
                _recordClock.Stop();
                ShowSpinner();
                TitleText.Text = "Transcribing";
                SubtitleText.Text = $"{Math.Max(1, (int)Math.Round(_recordClock.Elapsed.TotalSeconds))} s of audio";
                ShowChip(profileName);
                break;

            case DictationState.Processing:
                ShowSpinner();
                TitleText.Text = "Tidying with " + profileName;
                ShowChip(model);
                BodyText.Foreground = Muted;
                ShowBody(raw);
                width = WideWidth;
                expanded = true;
                break;

            case DictationState.Confirming:
                _previewShown = true;
                CheckIcon.Visibility = Visibility.Visible;
                TitleText.Text = "Ready to insert";
                ShowChip(profileName);
                ShowDiff(raw, preview);
                InsertButton.Content = string.IsNullOrEmpty(_hotkey) ? "Insert" : $"Insert   {_hotkey}";
                Actions.Visibility = Visibility.Visible;
                width = WideWidth;
                expanded = true;
                break;

            case DictationState.Inserting:
                ShowSpinner();
                TitleText.Text = "Inserting";
                break;
        }
        Display(width, expanded);
    }

    /// <summary>After text was inserted: a short receipt, with the AI's edits when there were any to see.</summary>
    public void ShowReceipt(InsertReceipt r)
    {
        ResetView();
        if (r.SafetyNet)
        {
            WarnIcon.Stroke = WarnStroke;
            WarnIcon.Visibility = Visibility.Visible;
            TitleText.Text = "Original words inserted";
            ShowBody("The AI's edit changed too much (or came back empty), so your words went in unchanged. You can adjust the safety net on the profile's page.");
            Display(WideWidth, expanded: true);
            HideAfter(TimeSpan.FromSeconds(6));
            return;
        }

        CheckIcon.Visibility = Visibility.Visible;
        TitleText.Text = "Inserted";
        SubtitleText.Text = $"{r.Words} {(r.Words == 1 ? "word" : "words")} · {r.Elapsed.TotalSeconds:0.0} s";
        var diff = WordDiff.Compute(r.Raw, r.Inserted);
        if (r.Edited && !_previewShown && WordDiff.HasChanges(diff))
        {
            DiffText.Render(BodyText, diff, DiffRemoved, DiffAdded, maxWords: 60);
            BodyText.Visibility = Visibility.Visible;
            Display(WideWidth, expanded: true);
            HideAfter(TimeSpan.FromSeconds(Math.Clamp(r.Words / 3.5, 3, 8)));
        }
        else
        {
            Display(NarrowWidth, expanded: false);
            HideAfter(TimeSpan.FromSeconds(2.5));
        }
    }

    /// <summary>The cycle-profile hotkey was pressed.</summary>
    public void ShowProfile(string name, int index, int count)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_pinnedByState) return; // mid-dictation: the chip already shows the profile
            ResetView();
            Indicator.Visibility = Visibility.Collapsed;
            TitleText.Inlines.Add(new Run("Profile   ") { Foreground = Muted, FontWeight = FontWeights.Normal });
            TitleText.Inlines.Add(new Run(name));
            Dots.Children.Clear();
            for (var i = 0; i < count; i++)
                Dots.Children.Add(new Border
                {
                    Width = i == index ? 16 : 6, Height = 6, CornerRadius = new CornerRadius(3),
                    Margin = new Thickness(5, 0, 0, 0),
                    Background = i == index ? Brushes.White : new SolidColorBrush(Color.FromArgb(0x4D, 0xFF, 0xFF, 0xFF)),
                });
            Dots.Visibility = count > 1 ? Visibility.Visible : Visibility.Collapsed;
            Display(NarrowWidth, expanded: false);
            HideAfter(TimeSpan.FromSeconds(1.5));
        });
    }

    public void SetLevel(float level) => Dispatcher.BeginInvoke(() =>
    {
        if (_state != DictationState.Recording) return;
        Array.Copy(_levels, 1, _levels, 0, WaveBars - 1);
        _levels[^1] = Math.Sqrt(Math.Clamp(level, 0f, 1f)); // perceptual: quiet speech still moves the bars
        DrawWave();
    });

    void DrawWave()
    {
        for (var i = 0; i < WaveBars; i++)
            ((Rectangle)Wave.Children[i]).Height = 4 + 24 * _levels[i];
    }

    public void ShowMessage(string text, NoticeLevel level)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_pinnedByState && _state != DictationState.Idle && level == NoticeLevel.Info) return;
            ResetView();
            if (level == NoticeLevel.Info)
            {
                RecDot.Fill = Muted;
                RecDot.Visibility = Visibility.Visible;
            }
            else
            {
                WarnIcon.Stroke = level == NoticeLevel.Error ? ErrorStroke : WarnStroke;
                WarnIcon.Visibility = Visibility.Visible;
            }
            TitleText.Text = level switch
            {
                NoticeLevel.Error => "Something went wrong",
                NoticeLevel.Warning => "Heads up",
                _ => "Oberton",
            };
            ShowBody(text);
            Display(WideWidth, expanded: true);
            HideAfter(TimeSpan.FromSeconds(Math.Clamp(text.Length / 15.0, 3, 9)));
        });
    }

    static string FormatClock(TimeSpan t) => $"{(int)t.TotalMinutes}:{t.Seconds:00}";

    /// <summary>Long text: keep the end, which is what the user said last.</summary>
    static string Tail(string text, int max)
    {
        if (text.Length <= max) return text;
        var tail = text[^max..];
        var sp = tail.IndexOf(' ');
        return "…" + (sp > 0 && sp < 40 ? tail[(sp + 1)..] : tail);
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => CancelRequested?.Invoke();
    void Insert_Click(object sender, RoutedEventArgs e) => InsertRequested?.Invoke();
    void Raw_Click(object sender, RoutedEventArgs e) => InsertRawRequested?.Invoke();
}
