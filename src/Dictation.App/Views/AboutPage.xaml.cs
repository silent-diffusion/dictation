using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;

namespace Dictation.App.Views;

public partial class AboutPage : UserControl
{
    public AboutPage()
    {
        InitializeComponent();
        VersionText.Text = ($"{AppInfo.Name} {AppInfo.VersionText}" + (AppPaths.IsDevelopmentCopy ? "  // development copy" : "")).ToUpper();
        // The shortcuts the explanation mentions are the ones actually set
        var s = App.Services.Settings.Current;
        if (!string.IsNullOrEmpty(s.Hotkey)) DictateKey.Text = s.Hotkey;
        if (!string.IsNullOrEmpty(s.SpeakHotkey)) SpeakKey.Text = s.SpeakHotkey;
    }

    void Repo_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(AppInfo.RepositoryUrl) { UseShellExecute = true });
}
