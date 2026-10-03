using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;

namespace Dictation.App.Views;

public partial class AdvancedPage : UserControl
{
    public AdvancedPage()
    {
        InitializeComponent();
        PathsText.Text =
            $"App root:   {AppPaths.Root}\nSettings:   {Path.Combine(AppPaths.DataDir, "settings.json")}\n" +
            $"Profiles:   {Path.Combine(AppPaths.DataDir, "profiles.json")}\nLogs:       {AppPaths.LogDir}\n" +
            $"Models:     {AppPaths.ModelsDir}\nRuntimes:   {AppPaths.RuntimeDir}";
        Loaded += async (_, _) =>
        {
            var llm = await App.Services.Llm.ListModelsAsync();
            var whisperDir = Path.Combine(AppPaths.ModelsDir, "whisper");
            var whisper = Directory.Exists(whisperDir)
                ? Directory.GetDirectories(whisperDir, "models--*").Select(d => Path.GetFileName(d)[8..].Replace("--", "/")).ToList()
                : new List<string>();
            ModelsText.Text =
                "Speech (models\\whisper):  " + (whisper.Count == 0 ? "none" : string.Join(", ", whisper)) + "\n" +
                "Language models (models\\ollama):  " + (llm.Count == 0 ? "none (or runtime not running)" : string.Join(", ", llm));
        };
    }

    static void Open(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    void OpenData_Click(object sender, RoutedEventArgs e) => Open(AppPaths.DataDir);
    void OpenLogs_Click(object sender, RoutedEventArgs e) => Open(AppPaths.LogDir);
    void OpenModels_Click(object sender, RoutedEventArgs e) => Open(AppPaths.ModelsDir);
}
