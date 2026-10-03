using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Dictation.Core.Insertion;
using Dictation.Core.Session;

namespace Dictation.App.Views;

/// <summary>
/// Small always-on-top status window. It is created with WS_EX_NOACTIVATE so it can never take keyboard
/// focus away from the application being dictated into.
/// </summary>
public partial class OverlayWindow : Window
{
    readonly DispatcherTimer _hideTimer = new();
    DictationState _state = DictationState.Idle;
    string _hotkey = "";
    bool _pinnedByState;

    public event Action? CancelRequested;
    public event Action? InsertRawRequested;

    public OverlayWindow()
    {
        InitializeComponent();
        _hideTimer.Tick += (_, _) => { _hideTimer.Stop(); if (!_pinnedByState) Hide(); };
        SizeChanged += (_, _) => Reposition();
    }

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
        Top = wa.Bottom - ActualHeight - 24;
    }

    void Display()
    {
        _hideTimer.Stop();
        if (!IsVisible) { Show(); }
        Reposition();
    }

    public void ShowState(DictationState state, string profileName, string transcriptForConfirm = "")
    {
        _state = state;
        ProfileText.Text = profileName;
        _pinnedByState = state != DictationState.Idle;
        if (state == DictationState.Idle) { _hideTimer.Interval = TimeSpan.FromMilliseconds(250); _hideTimer.Start(); return; }

        RawButton.Visibility = state == DictationState.Confirming ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.Visibility = state is DictationState.Recording or DictationState.Confirming ? Visibility.Visible : Visibility.Collapsed;
        Level.Visibility = state == DictationState.Recording ? Visibility.Visible : Visibility.Collapsed;
        Dot.BeginAnimation(OpacityProperty, null);
        switch (state)
        {
            case DictationState.Starting:
                SetStatus("Starting…", "#FFB020"); break;
            case DictationState.Recording:
                SetStatus("Listening…", "#FF5A5A");
                TranscriptText.Text = "Start speaking…";
                TranscriptText.Opacity = 0.5;
                Level.Value = 0;
                Dot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.25, TimeSpan.FromMilliseconds(700))
                    { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
                break;
            case DictationState.Transcribing:
                SetStatus("Finishing transcription…", "#FFB020"); break;
            case DictationState.Processing:
                SetStatus($"Cleaning up · {profileName}…", "#5AA9FF"); ProfileText.Text = ""; break;
            case DictationState.Confirming:
                SetStatus($"Review — press {_hotkey} to insert, Esc to discard", "#6FD16F");
                SetTranscript(transcriptForConfirm); break;
            case DictationState.Inserting:
                SetStatus("Inserting…", "#6FD16F"); break;
        }
        Display();
    }

    void SetStatus(string text, string color)
    {
        StatusText.Text = text;
        Dot.Fill = (Brush)new BrushConverter().ConvertFromString(color)!;
    }

    public void SetTranscript(string text)
    {
        Dispatcher.BeginInvoke(() =>
        {
            TranscriptText.Opacity = 1;
            const int max = 260;
            if (text.Length > max)
            {
                var tail = text[^max..];
                var sp = tail.IndexOf(' ');
                text = "…" + (sp > 0 && sp < 40 ? tail[(sp + 1)..] : tail);
            }
            TranscriptText.Text = text;
        });
    }

    public void SetLevel(float level) => Dispatcher.BeginInvoke(() => Level.Value = level);

    public void ShowMessage(string text, NoticeLevel level)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_pinnedByState && _state != DictationState.Idle && level == NoticeLevel.Info) return;
            var color = level switch { NoticeLevel.Error => "#FF5A5A", NoticeLevel.Warning => "#FFB020", _ => "#5AA9FF" };
            RawButton.Visibility = CancelButton.Visibility = Level.Visibility = Visibility.Collapsed;
            Dot.BeginAnimation(OpacityProperty, null);
            SetStatus(level == NoticeLevel.Error ? "Dictation problem" : "Dictation", color);
            ProfileText.Text = "";
            TranscriptText.Opacity = 1;
            TranscriptText.Text = text;
            Display();
            _hideTimer.Interval = TimeSpan.FromSeconds(Math.Clamp(text.Length / 15.0, 3, 9));
            _hideTimer.Start();
        });
    }

    void Cancel_Click(object sender, RoutedEventArgs e) => CancelRequested?.Invoke();
    void Raw_Click(object sender, RoutedEventArgs e) => InsertRawRequested?.Invoke();
}
