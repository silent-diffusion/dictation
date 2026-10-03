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
/// The pill (bottom center of the screen by default; the position is a setting). Small while you talk; it grows only when it has text to show
/// (the cleanup, a preview, a receipt, a message). It is created with WS_EX_NOACTIVATE so it can never take
/// keyboard focus away from the application being dictated into.
/// </summary>
public partial class OverlayWindow : Window
{
    const double CompactWidth = 440, WideWidth = 470, NarrowWidth = 360, CompareWidth = 640;
    /// <summary>The "Inserted" receipt is dimmed so it doesn't compete with the text; hovering brings it back.</summary>
    const double ReceiptDim = 0.55;
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
    bool _pinnedByState;
    InsertReceipt? _receipt; // set while the receipt is showing
    bool _compareOpen;

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
        const double edge = 8; // plus the window's 16 px shadow margin: the pill sits ~24 px from the screen edge
        var pos = (int)App.Services.Settings.Current.OverlayPosition; // row by row: 0-2 top, 3-5 middle, 6-8 bottom
        var (column, row) = (pos % 3, pos / 3);
        Left = column switch
        {
            0 => wa.Left + edge,
            1 => wa.Left + (wa.Width - ActualWidth) / 2,
            _ => wa.Right - ActualWidth - edge,
        };
        Top = row switch
        {
            0 => wa.Top + edge,
            1 => wa.Top + (wa.Height - ActualHeight) / 2,
            _ => wa.Bottom - ActualHeight - edge,
        };
    }

    void Display(double width, bool expanded)
    {
        Body.Width = width;
        Card.CornerRadius = new CornerRadius(expanded ? 20 : 28);
        var opacity = Math.Clamp(App.Services.Settings.Current.OverlayOpacity, 0.6, 1.0);
        Card.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), 0x16, 0x16, 0x18));
        Opacity = 1;
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
        BodyText.Visibility = Actions.Visibility = Compare.Visibility = Visibility.Collapsed;
        _receipt = null;
        _compareOpen = false;
        Card.Cursor = null;
        CancelButton.ToolTip = "Cancel";
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
    /// <param name="live">Text was already typed while speaking; this cleanup is the final pass over it.</param>
    public void ShowState(DictationState state, string profileName, string raw = "", string preview = "", string model = "",
        bool live = false)
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
                TitleText.Text = (live ? "Final pass with " : "Tidying with ") + profileName;
                ShowChip(model);
                BodyText.Foreground = Muted;
                ShowBody(raw);
                width = WideWidth;
                expanded = true;
                break;

            case DictationState.Confirming:
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

    /// <summary>After text was inserted: a small, dimmed receipt. Hover to see it clearly; click it to compare
    /// what you said with the AI's edit side by side.</summary>
    public void ShowReceipt(InsertReceipt r)
    {
        ResetView();
        _receipt = r;
        Card.Cursor = System.Windows.Input.Cursors.Hand;
        if (r.SafetyNet || r.Note != null)
        {
            WarnIcon.Stroke = WarnStroke;
            WarnIcon.Visibility = Visibility.Visible;
            TitleText.Text = !r.SafetyNet ? "Inserted" : r.Edited ? "Partly edited" : "Original words inserted";
            ShowBody(r.Note ?? "The AI's edit changed too much (or came back empty), so your words went in unchanged. " +
                     "You can adjust the safety net on the profile's page.");
            Display(WideWidth, expanded: true);
            HideAfter(TimeSpan.FromSeconds(6));
            return;
        }

        CheckIcon.Visibility = Visibility.Visible;
        TitleText.Text = "Inserted";
        SubtitleText.Text = $"{r.Words} {(r.Words == 1 ? "word" : "words")} · {r.Elapsed.TotalSeconds:0.0} s";
        Display(NarrowWidth, expanded: false);
        Opacity = ReceiptDim;
        HideAfter(TimeSpan.FromSeconds(3));
    }

    void OpenCompare(InsertReceipt r)
    {
        _compareOpen = true;
        BodyText.Visibility = Visibility.Collapsed;
        CompareRaw.Text = r.Raw;
        DiffText.Render(CompareEdited, WordDiff.Compute(r.Raw, r.Inserted.Trim()), DiffRemoved, DiffAdded);
        Compare.Visibility = Visibility.Visible;
        CancelButton.Visibility = Visibility.Visible; // closes the receipt
        CancelButton.ToolTip = "Close";
        Card.Cursor = null;
        Display(CompareWidth, expanded: true);
    }

    void Card_MouseEnter(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (_receipt == null) return;
        _hideTimer.Stop(); // stays while the pointer is on it
        Opacity = 1;
    }

    void Card_MouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (_receipt == null) return;
        if (!_compareOpen && !_receipt.SafetyNet && _receipt.Note == null) Opacity = ReceiptDim;
        HideAfter(TimeSpan.FromSeconds(_compareOpen ? 4 : 2));
    }

    void Card_MouseLeftButtonUp(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (_receipt != null && !_compareOpen) OpenCompare(_receipt);
    }

    /// <summary>Settings › Appearance changed the position: flash the pill where it will appear.</summary>
    public void ShowPositionPreview()
    {
        if (_pinnedByState) return;
        ResetView();
        RecDot.Visibility = Visibility.Visible;
        TitleText.Text = "Dictation appears here";
        Display(NarrowWidth, expanded: false);
        HideAfter(TimeSpan.FromSeconds(1.5));
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

    void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (_receipt != null) { _hideTimer.Stop(); Hide(); return; } // closing a receipt, not cancelling a dictation
        CancelRequested?.Invoke();
    }
    void Insert_Click(object sender, RoutedEventArgs e) => InsertRequested?.Invoke();
    void Raw_Click(object sender, RoutedEventArgs e) => InsertRawRequested?.Invoke();
}
