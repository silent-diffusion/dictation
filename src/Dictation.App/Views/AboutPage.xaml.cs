using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;

namespace Dictation.App.Views;

public partial class AboutPage : UserControl
{
    readonly UpdateService _updates = new();
    UpdateInfo? _info;

    public AboutPage()
    {
        InitializeComponent();
        DataContext = App.Services.Settings.Current;
        AutoSave.Hook(this, () => App.Services.Settings.Save());
        VersionText.Text = $"{AppInfo.Name} {AppInfo.VersionText}" + (AppPaths.IsDevelopmentCopy ? "  (development copy)" : "");
        if (App.AvailableUpdate is { } pending) Show(pending);
    }

    void Show(UpdateInfo info)
    {
        _info = info;
        StatusText.Text = $"Version {info.Version.ToString(3)} is available (you have {AppInfo.VersionText}).";
        NotesText.Text = info.Notes.Length > 1500 ? info.Notes[..1500] + "…" : info.Notes;
        if (AppPaths.IsDevelopmentCopy)
        {
            StatusText.Text += " This is a development copy: update it with \"git pull\" instead.";
            return;
        }
        InstallButton.Content = info.Size > 0 ? $"Download and install ({info.Size / 1048576.0:0} MB)" : "Download and install";
        InstallButton.Visibility = Visibility.Visible;
    }

    async void Check_Click(object sender, RoutedEventArgs e)
    {
        CheckButton.IsEnabled = false;
        InstallButton.Visibility = Visibility.Collapsed;
        NotesText.Text = "";
        StatusText.Text = "Checking…";
        try
        {
            var info = await _updates.CheckAsync();
            if (info == null) StatusText.Text = $"You're up to date ({AppInfo.VersionText}).";
            else Show(info);
        }
        catch (UserFacingException ex) { StatusText.Text = ex.Message; }
        catch (Exception ex) { Log.Error("Update check failed", ex); StatusText.Text = "The update check failed. See the log for details."; }
        finally { CheckButton.IsEnabled = true; }
    }

    async void Install_Click(object sender, RoutedEventArgs e)
    {
        if (_info == null) return;
        CheckButton.IsEnabled = InstallButton.IsEnabled = false;
        Bar.Visibility = Visibility.Visible;
        StatusText.Text = "Downloading the update…";
        try
        {
            var path = await _updates.DownloadAsync(_info, new Progress<double>(f => Bar.Value = f));
            StatusText.Text = "Installing… Oberton will restart by itself.";
            UpdateService.LaunchInstaller(path);
            await Task.Delay(800);
            ((App)Application.Current).Quit();
        }
        catch (UserFacingException ex) { StatusText.Text = ex.Message; }
        catch (Exception ex) { Log.Error("Update install failed", ex); StatusText.Text = "The update could not be installed: " + ex.Message; }
        finally
        {
            CheckButton.IsEnabled = InstallButton.IsEnabled = true;
            Bar.Visibility = Visibility.Collapsed;
        }
    }

    void Repo_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(AppInfo.RepositoryUrl) { UseShellExecute = true });
}
