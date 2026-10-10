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
/// keyboard focus away from the application being dictated into. It can be dragged anywhere (see <see cref="WindowDrag"/>).
/// </summary>
public partial class OverlayWindow : Window
{
    const double CompactWidth = 440, WideWidth = 470, NarrowWidth = 360, CompareWideWidth = 860, CompareStackWidth = 560;
    /// <summary>The "Inserted" receipt is dimmed so it doesn't compete with the text; hovering brings it back.</summary>
    const double ReceiptDim = 0.55;
    /// <summary>Columns of the level meter (each a stack of <see cref="WaveDots"/> dots, lit from the bottom).</summary>
    const int WaveBars = 22, WaveDots = 5;

    // Always dark: paper-colored text on an ink capsule. Red is only the recording dot.
    static readonly Brush Paper = Freeze(new SolidColorBrush(Color.FromRgb(0xE8, 0xE7, 0xE3)));
    static readonly Brush Muted = Freeze(new SolidColorBrush(Color.FromArgb(0xB3, 0xE8, 0xE7, 0xE3)));
    static readonly Brush DiffRemoved = Freeze(new SolidColorBrush(Color.FromArgb(0x70, 0xE8, 0xE7, 0xE3)));
    static readonly Brush WarnStroke = Paper;
    static readonly Brush RecordFill = Freeze(new SolidColorBrush(Color.FromRgb(0xFF, 0x46, 0x36)));

    /// <summary>The accent, in its dark-paper version (the overlay is dark in both themes): words the AI added, errors,
    /// and the working spinner.</summary>
    static Brush Accent => Application.Current.TryFindResource("Ob.AccentOnDark") as Brush ?? Paper;

    readonly DispatcherTimer _hideTimer = new();
    readonly DispatcherTimer _clockTimer = new() { Interval = TimeSpan.FromMilliseconds(200) };
    readonly Stopwatch _recordClock = new();
    readonly double[] _levels = new double[WaveBars];
    DictationState _state = DictationState.Idle;
    string _hotkey = "";
    bool _pinnedByState;
    InsertReceipt? _receipt; // set while the receipt is showing
    string _liveText = ""; // the transcript so far, while recording
    bool _engineLoading;
    bool _compareOpen;
    readonly WindowDrag _drag;

    public event Action? CancelRequested;
    public event Action? InsertRequested;
    public event Action? InsertRawRequested;

    public OverlayWindow()
    {
        InitializeComponent();
        _drag = new WindowDrag(this);
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); if (!_pinnedByState) Conceal(); };
        _clockTimer.Tick += (_, _) => TitleText.Text = FormatClock(_recordClock.Elapsed);
        SizeChanged += (_, _) => Reposition();
        for (var i = 0; i < WaveBars; i++)
        {
            var column = new StackPanel { Margin = new Thickness(0, 0, 3, 0), VerticalAlignment = VerticalAlignment.Center };
            for (var d = 0; d < WaveDots; d++)
                column.Children.Add(new Ellipse { Width = 3, Height = 3, Margin = new Thickness(0, 1, 0, 1), Fill = Paper, Opacity = 0.2 });
            Wave.Children.Add(column);
        }
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
        if (_drag.Place()) return; // the user dragged it somewhere
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
        var opacity = Math.Clamp(App.Services.Settings.Current.OverlayOpacity, 0.3, 1.0);
        Card.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Round(opacity * 255), 0x0D, 0x0D, 0x0C));
        Opacity = 1;
        _hideTimer.Stop();
        if (!IsVisible) Show();
        Reposition();
    }

    /// <summary>
    /// Hide without leaving the last picture behind: Windows shows a layered window's last frame again for a moment
    /// when it reappears, which flashed the old receipt at the start of the next dictation. So render one fully
    /// transparent frame first, then hide.
    /// </summary>
    void Conceal()
    {
        _hideTimer.Stop();
        if (!IsVisible) return;
        Opacity = 0;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            if (Opacity == 0 && !_pinnedByState) Hide(); // unless it was shown again meanwhile
        });
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
        BodyText.Visibility = Actions.Visibility = Compare.Visibility = LiveText.Visibility = Visibility.Collapsed;
        _receipt = null;
        _compareOpen = false;
        StateDecor.Text = "";
        FocusInserted(false);
        Stack(false);
        Card.Cursor = null;
        CancelButton.ToolTip = "Cancel this dictation";
        CancelLabel.Visibility = Visibility.Visible;
        CancelButton.Padding = new Thickness(12, 0, 12, 0);
        BodyText.Foreground = Paper;
        BodyText.Inlines.Clear();
        TitleText.Inlines.Clear();
        TitleText.FontWeight = FontWeights.SemiBold;
        SubtitleText.Text = "";
    }

    void ShowSpinner()
    {
        Spinner.Visibility = Visibility.Visible;
        SpinnerArc.Stroke = Accent;
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

    /// <param name="raw">The transcript being cleaned up or previewed.</param>
    /// <param name="preview">The cleaned-up text waiting for confirmation.</param>
    /// <param name="model">The AI model doing the cleanup.</param>
    /// <param name="live">Text was already typed while speaking; this cleanup is the final pass over it.</param>
    public void ShowState(DictationState state, string profileName, string raw = "", string preview = "", string model = "",
        bool live = false)
    {
        if (state != DictationState.Idle) EndTrial(null); // a real dictation takes over from a Try it preview
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
                _liveText = ""; // a new dictation
                StateDecor.Text = "処理中";
                ShowSpinner();
                TitleText.Text = "STARTING";
                ShowChip(profileName);
                CancelButton.Visibility = Visibility.Visible;
                break;

            case DictationState.Recording:
                StateDecor.Text = "録音";
                RecDot.Visibility = Visibility.Visible;
                RecDot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.35, TimeSpan.FromMilliseconds(700))
                    { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
                TitleText.FontWeight = FontWeights.Normal;
                _recordClock.Restart();
                TitleText.Text = FormatClock(TimeSpan.Zero);
                _clockTimer.Start();
                Array.Clear(_levels);
                DrawWave();
                Wave.Visibility = Visibility.Visible;
                ShowChip(profileName);
                CancelButton.Visibility = Visibility.Visible;
                ShowLiveText();
                break;

            case DictationState.Transcribing:
                StateDecor.Text = "処理中";
                _recordClock.Stop();
                ShowSpinner();
                TitleText.Text = _engineLoading ? "LOADING SPEECH MODEL" : "TRANSCRIBING";
                SubtitleText.Text = $"{Math.Max(1, (int)Math.Round(_recordClock.Elapsed.TotalSeconds))} S OF AUDIO";
                ShowChip(profileName);
                CancelButton.Visibility = Visibility.Visible;
                ShowLiveText();
                break;

            case DictationState.Processing:
                StateDecor.Text = "処理中";
                ShowSpinner();
                TitleText.Text = (live ? "FINAL PASS // " : "TIDYING // ") + profileName.ToUpper();
                ShowChip(model);
                BodyText.Foreground = Muted;
                ShowBody(raw);
                CancelButton.Visibility = Visibility.Visible; // nothing is inserted if cancelled now
                width = WideWidth;
                expanded = true;
                break;

            case DictationState.Confirming:
                CheckIcon.Visibility = Visibility.Visible;
                TitleText.Text = "READY TO INSERT";
                ShowChip(profileName);
                ShowPreviewBoxes(raw, preview, App.Services.Profiles.Active.AutoProcess);
                InsertButton.Content = string.IsNullOrEmpty(_hotkey) ? "INSERT" : $"INSERT   {_hotkey.ToUpper()}";
                Actions.Visibility = Visibility.Visible;
                width = CompareWideWidth;
                expanded = true;
                break;

            case DictationState.Inserting:
                StateDecor.Text = "挿入";
                ShowSpinner();
                TitleText.Text = "INSERTING";
                break;
        }
        Display(width, expanded);
    }

    /// <summary>While recording: the words recognized so far, above the pill (the last few lines).</summary>
    public void SetLiveTranscript(string text)
    {
        _liveText = text;
        if (_state is DictationState.Recording or DictationState.Transcribing) ShowLiveText();
    }

    /// <summary>The speech model is loading while the user already speaks; recording goes on and it catches up.</summary>
    public void SetEngineLoading(bool loading)
    {
        _engineLoading = loading;
        if (_state is DictationState.Recording or DictationState.Transcribing) ShowLiveText();
        if (!loading && _state == DictationState.Transcribing) TitleText.Text = "TRANSCRIBING";
    }

    void ShowLiveText()
    {
        LiveText.Inlines.Clear();
        if (_liveText.Length > 0)
        {
            LiveText.Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xE8, 0xE7, 0xE3));
            LiveText.Text = Tail(_liveText, 180);
        }
        else if (_engineLoading)
        {
            LiveText.Foreground = Muted;
            LiveText.Text = "Loading the speech model… keep talking, it will catch up.";
        }
        LiveText.Visibility = LiveText.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
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
            TitleText.Text = !r.SafetyNet ? "INSERTED" : r.Edited ? "PARTLY EDITED" : "ORIGINAL WORDS INSERTED";
            ShowBody(r.Note ?? "The AI's edit changed too much (or came back empty), so your words went in unchanged. " +
                     "You can adjust the safety net on the profile's page.");
            Display(WideWidth, expanded: true);
            HideAfter(TimeSpan.FromSeconds(6));
            return;
        }

        CheckIcon.Visibility = Visibility.Visible;
        StateDecor.Text = "挿入";
        TitleText.Text = "INSERTED";
        SubtitleText.Text = $"{r.Words} {(r.Words == 1 ? "WORD" : "WORDS")} // {r.Elapsed.TotalSeconds:0.0} S";
        Display(NarrowWidth, expanded: false);
        Opacity = ReceiptDim;
        HideAfter(TimeSpan.FromSeconds(3));
    }

    /// <summary>The three boxes used everywhere in the app: Transcription · AI Edit (struck through / added) · Inserted.</summary>
    void OpenCompare(InsertReceipt r)
    {
        _compareOpen = true;
        BodyText.Visibility = Visibility.Collapsed;
        FillCompare(r.Raw, r.AiEdit, r.Inserted, r.SafetyNet
            ? "The safety net rejected the AI's edit, so your words went in as spoken."
            : "No AI edit for this dictation.");
        CancelButton.Visibility = Visibility.Visible; // closes the receipt
        CancelButton.ToolTip = "Close";
        CancelLabel.Visibility = Visibility.Collapsed; // just ✕ here
        CancelButton.Padding = new Thickness(0);
        Card.Cursor = null;
        Stack(true);
        Display(CompareStackWidth, expanded: true);
    }

    /// <summary>After a dictation went in, the three boxes read top to bottom; before it (the preview), side by side.</summary>
    void Stack(bool on)
    {
        var boxes = new FrameworkElement[] { RawPanel, EditDivider, EditPanel, InsertDivider, InsertFrame };
        for (var i = 0; i < boxes.Length; i++)
        {
            Grid.SetColumn(boxes[i], on ? 0 : i);
            Grid.SetColumnSpan(boxes[i], on ? 5 : 1);
            Grid.SetRow(boxes[i], on ? i : 0);
        }
        // Dividers turn from vertical lines between columns into horizontal rules between rows.
        foreach (var d in new[] { EditDivider, InsertDivider })
        {
            d.Width = on ? double.NaN : 1;
            d.Height = on ? 1 : double.NaN;
            d.Margin = on ? new Thickness(0, 9, 0, 9) : new Thickness(0);
            d.HorizontalAlignment = on ? HorizontalAlignment.Stretch : HorizontalAlignment.Center;
        }
        var cols = Compare.ColumnDefinitions;
        cols[1].Width = new GridLength(on ? 0 : 20);
        cols[2].Width = on ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        cols[3].Width = new GridLength(on ? 0 : 20);
        InsertColumn.Width = on ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        foreach (var box in new Control[] { CompareRaw, CompareEdited, CompareInserted }) box.MaxHeight = on ? 130 : 220;
    }

    string _copyRaw = "", _copyEdit = "", _copyInserted = "";

    void FillCompare(string raw, string? aiEdit, string inserted, string noEdit)
    {
        _copyRaw = raw;
        _copyInserted = inserted.Trim();
        _copyEdit = aiEdit?.Trim() ?? "";
        CompareRaw.Text = _copyRaw;
        CompareInserted.Text = _copyInserted;
        var paragraph = new Paragraph { Margin = new Thickness(0), LineHeight = 21 };
        if (aiEdit != null)
        {
            paragraph.Foreground = Paper;
            DiffText.Render(paragraph.Inlines, WordDiff.Compute(raw, aiEdit.Trim()), DiffRemoved, Accent);
        }
        else
        {
            paragraph.Foreground = Muted;
            paragraph.Inlines.Add(new Run(noEdit));
        }
        CompareEdited.Document = new FlowDocument(paragraph) { PagePadding = new Thickness(0) };
        foreach (var b in new[] { "Raw", "Edit", "Inserted" }) SetCopyLabel(b, "COPY");
        Compare.Visibility = Visibility.Visible;
    }

    /// <summary>A box's Copy: the part selected in it, or the whole box. AI Edit copies the AI's own text (without the
    /// struck-through words) unless part of it is selected.</summary>
    void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string box }) return;
        var text = box switch
        {
            "Raw" => CompareRaw.SelectionLength > 0 ? CompareRaw.SelectedText : _copyRaw,
            "Edit" => !CompareEdited.Selection.IsEmpty ? CompareEdited.Selection.Text : _copyEdit,
            _ => CompareInserted.SelectionLength > 0 ? CompareInserted.SelectedText : _copyInserted,
        };
        if (string.IsNullOrWhiteSpace(text)) return;
        try { Clipboard.SetText(text.Trim()); } catch { return; }
        SetCopyLabel(box, "COPIED ✓");
        var reset = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.4) };
        reset.Tick += (_, _) => { reset.Stop(); SetCopyLabel(box, "COPY"); };
        reset.Start();
        e.Handled = true;
    }

    void SetCopyLabel(string box, string label)
    {
        foreach (var b in FindCopyButtons()) if ((string)b.Tag == box) b.Content = label;
    }

    IEnumerable<Button> FindCopyButtons()
    {
        static IEnumerable<DependencyObject> All(DependencyObject root)
        {
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            {
                var c = VisualTreeHelper.GetChild(root, i);
                yield return c;
                foreach (var d in All(c)) yield return d;
            }
        }
        return All(Compare).OfType<Button>().Where(b => b.Tag is "Raw" or "Edit" or "Inserted");
    }

    /// <summary>Before inserting: the three boxes, with the one that will go in brought forward.</summary>
    void ShowPreviewBoxes(string raw, string toInsert, bool usesAi)
    {
        FillCompare(raw, usesAi ? toInsert : null, toInsert, "No AI edit: this profile doesn't use AI.");
        FocusInserted(true);
    }

    /// <summary>The Inserted box pops out (a little larger, on a more solid backing); the other two step back.</summary>
    void FocusInserted(bool on)
    {
        RawPanel.Opacity = EditPanel.Opacity = on ? 0.45 : 1;
        InsertColumn.Width = new GridLength(on ? 1.4 : 1, GridUnitType.Star);
        InsertDivider.Visibility = on ? Visibility.Hidden : Visibility.Visible;
        InsertFrame.Background = on ? new SolidColorBrush(Color.FromArgb(0x1F, 0xE8, 0xE7, 0xE3)) : Brushes.Transparent;
        InsertFrame.BorderBrush = on ? new SolidColorBrush(Color.FromArgb(0x66, 0xE8, 0xE7, 0xE3)) : Brushes.Transparent;
        InsertFrame.Padding = on ? new Thickness(14, 10, 14, 12) : new Thickness(0);
        InsertLabel.Foreground = on ? Paper : new SolidColorBrush(Color.FromArgb(0x99, 0xE8, 0xE7, 0xE3));
        CompareInserted.FontSize = on ? 15.5 : 14;
        if (on)
        {
            var pop = new DoubleAnimation(0.96, 1.02, TimeSpan.FromMilliseconds(220)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
            InsertScale.BeginAnimation(ScaleTransform.ScaleXProperty, pop);
            InsertScale.BeginAnimation(ScaleTransform.ScaleYProperty, pop);
        }
        else
        {
            InsertScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            InsertScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            InsertScale.ScaleX = InsertScale.ScaleY = 1;
        }
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
        _drag.Reset(); // a new position setting wins over where it was dragged
        if (_pinnedByState) return;
        ResetView();
        RecDot.Visibility = Visibility.Visible;
        TitleText.Text = "DICTATION APPEARS HERE";
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
            TitleText.Inlines.Add(new Run("PROFILE   ") { Foreground = Muted, FontWeight = FontWeights.Normal });
            TitleText.Inlines.Add(new Run(name));
            Dots.Children.Clear();
            for (var i = 0; i < count; i++)
                Dots.Children.Add(new Border
                {
                    Width = i == index ? 16 : 6, Height = 6, CornerRadius = new CornerRadius(3),
                    Margin = new Thickness(5, 0, 0, 0),
                    Background = i == index ? Paper : new SolidColorBrush(Color.FromArgb(0x4D, 0xE8, 0xE7, 0xE3)),
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

    /// <summary>Each column lights as many dots, from the bottom, as its level reaches (at least one, so the meter
    /// reads as a row of dots in silence).</summary>
    void DrawWave()
    {
        for (var i = 0; i < WaveBars; i++)
        {
            var lit = Math.Max(1, (int)Math.Round(_levels[i] * WaveDots));
            var dots = ((StackPanel)Wave.Children[i]).Children;
            for (var d = 0; d < WaveDots; d++)
                dots[d].Opacity = WaveDots - d <= lit ? 0.95 : 0.2;
        }
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
                WarnIcon.Stroke = level == NoticeLevel.Error ? Accent : WarnStroke;
                WarnIcon.Visibility = Visibility.Visible;
            }
            TitleText.Text = level switch
            {
                NoticeLevel.Error => "SOMETHING WENT WRONG",
                NoticeLevel.Warning => "HEADS UP",
                _ => "OBERTON",
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
        if (_trial != null) { EndTrial(null); return; }
        if (_receipt != null) { Conceal(); return; } // closing a receipt, not cancelling a dictation
        CancelRequested?.Invoke();
    }
    void Insert_Click(object sender, RoutedEventArgs e)
    {
        if (_trial != null) EndTrial(_trialEdited);
        else InsertRequested?.Invoke();
    }

    void Raw_Click(object sender, RoutedEventArgs e)
    {
        if (_trial != null) EndTrial(_trialRaw);
        else InsertRawRequested?.Invoke();
    }

    // ----- a profile page's Try it, with "Preview before inserting" on -----

    TaskCompletionSource<string?>? _trial;
    string _trialRaw = "", _trialEdited = "";

    /// <summary>
    /// The same preview a dictation gets, for Try it: the edit with Insert, Use original and Discard. Returns the text
    /// that would be inserted, or null when discarded. Nothing is inserted anywhere.
    /// </summary>
    public Task<string?> PreviewTrialAsync(string profileName, string raw, string edited, bool usesAi = true)
    {
        EndTrial(null);
        ResetView();
        var tcs = new TaskCompletionSource<string?>();
        _trial = tcs;
        _trialRaw = raw;
        _trialEdited = edited;
        CheckIcon.Visibility = Visibility.Visible;
        TitleText.Text = "READY TO INSERT";
        ShowChip("Try it · " + profileName);
        ShowPreviewBoxes(raw, edited, usesAi);
        InsertButton.Content = "INSERT";
        Actions.Visibility = Visibility.Visible;
        Display(CompareWideWidth, expanded: true);
        return tcs.Task;
    }

    void EndTrial(string? result)
    {
        var trial = _trial;
        if (trial == null) return;
        _trial = null;
        trial.TrySetResult(result);
        if (!_pinnedByState) HideAfter(TimeSpan.FromMilliseconds(150));
    }
}
