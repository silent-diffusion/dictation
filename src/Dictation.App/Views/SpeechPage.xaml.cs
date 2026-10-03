using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;

namespace Dictation.App.Views;

public partial class SpeechPage : UserControl
{
    public SpeechPage()
    {
        InitializeComponent();
        DataContext = App.Services.Settings.Current;
        AutoSave.Hook(this, () => App.Services.Settings.Save());
        StatusText.Text = App.Services.Status.Speech;
        App.Services.Status.PropertyChanged += (_, _) => StatusText.Text = App.Services.Status.Speech;
        Loaded += (_, _) => UpdateNote();
        LostKeyboardFocus += (_, _) => UpdateNote();
    }

    void UpdateNote()
    {
        var model = App.Services.Settings.Current.Asr.Model;
        var dir = Path.Combine(AppPaths.ModelsDir, "whisper");
        var installed = Directory.Exists(dir) && Directory.GetDirectories(dir, "models--*").Any(d =>
            d.Contains(model.Replace("/", "--"), StringComparison.OrdinalIgnoreCase));
        ModelNote.Text = installed
            ? "Installed locally."
            : $"Not detected in models\\whisper. Download it once with:  scripts\\setup.ps1 -WhisperModel {model}  (needs internet; the app itself never goes online). " +
              "Some models are stored under a different repository name, so this check can be wrong.";
    }

    async void Restart_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Settings.Save();
        await App.RestartSpeechAsync();
    }
}
