using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Setup;
using Dictation.Core.Speech;

namespace Dictation.App.Views;

public partial class ReadAloudPage : UserControl
{
    const string Sample = "Hello! This is how Oberton sounds when it reads to you. Select any text and press the shortcut to hear it.";
    CancellationTokenSource? _install;

    public ReadAloudPage()
    {
        InitializeComponent();
        var s = App.Services.Settings.Current;
        VoiceBox.ItemsSource = VoiceCatalog.All();
        DataContext = s;
        var windows = WindowsSpeech.InstalledVoices().Count;
        VoiceNote.Text = $"{VoiceCatalog.KokoroVoices.Count} Kokoro voices (natural; one download, English plus Spanish, French, " +
                         $"Italian, Portuguese and Hindi) and {windows} voice{(windows == 1 ? "" : "s")} installed with Windows " +
                         "(instant, no download). A profile can use its own voice: see its page under Speech to text.";
        BuildPositionPicker();
        Intro.Text = "Select text in any app and press " + s.SpeakHotkey + " to hear it. The voice (Kokoro) runs on this PC; " +
                     "nothing you read is sent anywhere.";
        HowTo.Text = $"Select text, then press {s.SpeakHotkey}. With nothing selected, Oberton offers to read your clipboard. " +
                     "Press the shortcut again (or ✕) to stop. Change the shortcut under Hotkeys.";
        ShowStatus();
        AutoSave.Hook(this, () => App.Services.Settings.Save());
        Unloaded += (_, _) => _install?.Cancel();
    }

    void BuildPositionPicker()
    {
        var s = App.Services.Settings.Current;
        foreach (var pos in Enum.GetValues<OverlayPosition>())
        {
            var name = AppearancePage.Describe(pos);
            var cell = new RadioButton
            {
                GroupName = "ReaderPosition", Style = (Style)FindResource("PositionCell"), Tag = pos, ToolTip = name,
                IsChecked = (s.ReaderPosition ?? s.OverlayPosition) == pos,
            };
            System.Windows.Automation.AutomationProperties.SetName(cell, name);
            cell.Checked += (_, _) =>
            {
                if (!IsLoaded || SamePlaceBox.IsChecked == true) return;
                s.ReaderPosition = pos;
                App.Services.Settings.Save();
                ReaderPositionName.Text = name;
                ((App)Application.Current).PreviewOverlay();
            };
            ReaderPositionGrid.Children.Add(cell);
        }
        SamePlaceBox.IsChecked = s.ReaderPosition == null;
        ShowPosition();
    }

    void ShowPosition()
    {
        var s = App.Services.Settings.Current;
        var same = SamePlaceBox.IsChecked == true;
        ReaderPositionPanel.IsEnabled = !same;
        ReaderPositionPanel.Opacity = same ? 0.45 : 1;
        ReaderPositionName.Text = AppearancePage.Describe(s.ReaderPosition ?? s.OverlayPosition);
    }

    void SamePlace_Changed(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        var s = App.Services.Settings.Current;
        s.ReaderPosition = SamePlaceBox.IsChecked == true ? null : s.ReaderPosition ?? s.OverlayPosition;
        App.Services.Settings.Save();
        foreach (var cell in ReaderPositionGrid.Children.OfType<RadioButton>())
            cell.IsChecked = (OverlayPosition)cell.Tag == (s.ReaderPosition ?? s.OverlayPosition);
        ShowPosition();
        ((App)Application.Current).PreviewOverlay();
    }

    void ShowStatus()
    {
        var installed = RuntimeInstaller.ReadAloudInstalled;
        StatusText.Text = installed ? "Voice installed" : "Voice not installed yet";
        StatusDetail.Text = installed
            ? "Ready to read."
            : $"A one-time download of about {RuntimeInstaller.ReadAloudDownloadMb} MB, also offered the first time you use Read aloud.";
        InstallButton.Content = "Download voice";
        InstallButton.Visibility = installed ? Visibility.Collapsed : Visibility.Visible;
        TryButton.IsEnabled = true;
    }

    async void Install_Click(object sender, RoutedEventArgs e)
    {
        InstallButton.IsEnabled = TryButton.IsEnabled = false;
        InstallBar.Visibility = Visibility.Visible;
        _install = new CancellationTokenSource();
        var progress = new Progress<SetupProgress>(p =>
        {
            StatusText.Text = p.Title;
            StatusDetail.Text = p.Detail;
            InstallBar.IsIndeterminate = p.Fraction == null;
            if (p.Fraction is { } f) InstallBar.Value = f;
        });
        try
        {
            await new RuntimeInstaller(App.Services.Settings, App.Services.OllamaHost).InstallReadAloudAsync(progress, _install.Token);
            ShowStatus();
        }
        catch (OperationCanceledException) { ShowStatus(); }
        catch (UserFacingException ex) { ShowStatus(); StatusDetail.Text = ex.Message; }
        catch (Exception ex)
        {
            Log.Error("Read aloud install failed", ex);
            ShowStatus();
            StatusDetail.Text = "The download failed. See the log, and try again.";
        }
        finally
        {
            InstallBar.Visibility = Visibility.Collapsed;
            InstallButton.IsEnabled = true;
            _install = null;
        }
    }

    void Try_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Settings.Save(); // use the voice and speed chosen here
        ((App)Application.Current).ReadAloud(Sample, App.Services.Settings.Current.TtsVoice);
    }
}
