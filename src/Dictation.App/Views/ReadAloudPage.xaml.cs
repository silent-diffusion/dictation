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
        DataContext = s;
        _filling = true;
        ModelBox.ItemsSource = VoiceCatalog.Models;
        ModelBox.SelectedItem = VoiceCatalog.Model(VoiceCatalog.ModelOf(s.TtsVoice));
        _filling = false;
        FillVoices();
        BuildPositionPicker();
        Intro.Text = "Select text in any app and press " + s.SpeakHotkey + " to hear it. The voices run on this PC; " +
                     "nothing you read is sent anywhere.";
        HowTo.Text = $"Select text, then press {s.SpeakHotkey}. With nothing selected, Oberton offers to read your clipboard. " +
                     "Press the shortcut again (or ✕) to stop. Change the shortcut under Hotkeys.";
        ShowStatus();
        AutoSave.Hook(this, () => App.Services.Settings.Save());
        Unloaded += (_, _) => _install?.Cancel();
    }

    /// <summary>A voice in the list; ones that still need downloading say so.</summary>
    sealed record VoiceItem(string Id, string Label);
    bool _filling;

    void FillVoices()
    {
        var s = App.Services.Settings.Current;
        var model = (ModelBox.SelectedItem as TtsModel)?.Id ?? VoiceCatalog.Kokoro;
        ModelNote.Text = VoiceCatalog.Model(model).Description;
        var items = VoiceCatalog.VoicesOf(model).Select(v => new VoiceItem(v.Id,
            v.Name + (VoiceCatalog.IsInstalled(v.Id) ? "" : VoiceCatalog.FindPiper(v.Id) is { } p ? $" · download {p.Mb} MB" : " · download"))).ToList();
        _filling = true;
        VoiceBox.ItemsSource = items;
        VoiceBox.SelectedItem = items.FirstOrDefault(i => i.Id == s.TtsVoice);
        _filling = false;
        if (VoiceBox.SelectedItem == null && items.Count > 0) VoiceBox.SelectedItem = items[0]; // a different model: its first voice
        if (items.Count == 0) ModelNote.Text += " No Windows voices are installed; add some under Windows Settings › Time & language › Speech.";
    }

    void ModelBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_filling) FillVoices();
    }

    void VoiceBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling || VoiceBox.SelectedItem is not VoiceItem v) return;
        App.Services.Settings.Current.TtsVoice = v.Id;
        ShowStatus();
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
        var voice = App.Services.Settings.Current.TtsVoice;
        var installed = VoiceCatalog.IsInstalled(voice);
        var name = VoiceCatalog.ShortName(voice);
        var piper = VoiceCatalog.FindPiper(voice);
        StatusText.Text = installed ? $"{name} is ready" : piper != null ? $"{name} isn't downloaded yet" : 
            VoiceCatalog.IsWindowsVoice(voice) ? $"{name} isn't installed" : "Kokoro isn't downloaded yet";
        StatusDetail.Text = installed ? $"{VoiceCatalog.Model(VoiceCatalog.ModelOf(voice)).Name} · ready to read."
            : piper != null ? $"A one-time download of about {piper.Mb} MB, also offered the first time you use it."
            : VoiceCatalog.IsWindowsVoice(voice) ? "That Windows voice isn't on this PC any more. Pick another one."
            : $"A one-time download of about {RuntimeInstaller.ReadAloudDownloadMb} MB, also offered the first time you use Read aloud.";
        InstallButton.Content = "DOWNLOAD VOICE";
        InstallButton.Visibility = installed || VoiceCatalog.IsWindowsVoice(voice) ? Visibility.Collapsed : Visibility.Visible;
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
            var installer = new RuntimeInstaller(App.Services.Settings, App.Services.OllamaHost);
            if (VoiceCatalog.FindPiper(App.Services.Settings.Current.TtsVoice) is { } piper)
                await installer.InstallPiperVoiceAsync(piper, progress, _install.Token);
            else await installer.InstallReadAloudAsync(progress, _install.Token);
            ShowStatus();
            FillVoices(); // drop the "download" marks
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
