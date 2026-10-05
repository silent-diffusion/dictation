using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;

namespace Dictation.App.Views;

public sealed record Choice(string Label, int Value);

public partial class HistorySettingsPage : UserControl
{
    public HistorySettingsPage()
    {
        InitializeComponent();
        var s = App.Services.Settings.Current;
        var limits = new List<int> { 10, 25, 50, 100, 200, 500 };
        if (s.HistoryLimit > 0 && !limits.Contains(s.HistoryLimit)) { limits.Add(s.HistoryLimit); limits.Sort(); }
        LimitBox.ItemsSource = limits.Select(n => new Choice(n + " dictations", n))
            .Append(new Choice("All of them (never delete)", 0)).ToList();
        DataContext = s;
        FolderText.Text = HistoryStore.Dir;
        UpdateSize();
        AutoSave.Hook(this, () =>
        {
            App.Services.Settings.Save();
            App.Services.History.Prune(); // a lower limit applies right away
            UpdateSize();
        });
    }

    void UpdateSize()
    {
        double mb = 0;
        try
        {
            if (Directory.Exists(HistoryStore.Dir))
                mb = new DirectoryInfo(HistoryStore.Dir).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length) / 1048576.0;
        }
        catch { }
        SizeText.Text = $"{App.Services.History.Entries.Count} dictations, {mb:0.#} MB.";
    }

    void Open_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(HistoryStore.Dir);
        try { Process.Start(new ProcessStartInfo("explorer.exe", HistoryStore.Dir) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn("Opening the history folder failed: " + ex.Message); }
    }

    void Clear_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("Delete every dictation in History, with its recording? This can't be undone.", AppInfo.Name,
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        App.Services.History.Clear();
        UpdateSize();
    }

    void ResetUsage_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("Reset the dashboard's daily counts (words per day, streaks, apps)? History itself is not touched.",
                AppInfo.Name, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        App.Services.Usage.Clear();
    }
}
