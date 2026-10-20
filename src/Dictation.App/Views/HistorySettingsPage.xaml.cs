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
        FillKeep(TextKeepBox, s.HistoryLimit, s.HistoryDays, audio: false, (count, days) => { s.HistoryLimit = count; s.HistoryDays = days; });
        FillKeep(AudioKeepBox, s.AudioLimit, s.AudioDays, audio: true, (count, days) => { s.AudioLimit = count; s.AudioDays = days; });
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

    /// <summary>A keep box: the newest so many, or a stretch of time, under two headings, plus keep everything (for the
    /// text) or as long as the text (for recordings). Choosing one saves it and prunes at once.</summary>
    void FillKeep(ComboBox box, int count, int days, bool audio, Action<int, int> set)
    {
        var counts = new List<int> { 10, 25, 50, 100, 200, 500 };
        if (count > 0 && !counts.Contains(count)) { counts.Add(count); counts.Sort(); }
        var ages = new List<int> { 1, 3, 7, 14, 30, 90, 365 };
        if (days > 0 && !ages.Contains(days)) { ages.Add(days); ages.Sort(); }
        ComboBoxItem Item(string label, int c, int d) => new() { Content = label, Tag = (c, d) };
        ComboBoxItem Heading(string label) => new()
        {
            Content = label, IsEnabled = false, FontSize = 10, FontFamily = (System.Windows.Media.FontFamily)FindResource("Ob.Mono"),
            Margin = new Thickness(0, 4, 0, 0),
        };
        box.Items.Add(audio ? Item("As long as the text", 0, 0) : Item("Everything (never delete)", 0, 0));
        box.Items.Add(Heading("THE NEWEST"));
        foreach (var c in counts) box.Items.Add(Item($"The newest {c} dictations", c, 0));
        box.Items.Add(Heading("FROM THE LAST"));
        foreach (var d in ages) box.Items.Add(Item($"The last {HistoryStore.DaysLabel(d)}", 0, d));
        box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => i.Tag is (int c, int d) && c == count && d == days) ?? box.Items[0];
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is not ComboBoxItem { Tag: (int c, int d) }) return;
            if (!audio && (c > 0 || d > 0) && !ConfirmShorter(c, d)) return;
            set(c, d);
            App.Services.Settings.Save();
            App.Services.History.Prune();
            UpdateSize();
        };
    }

    /// <summary>Text kept for less time than now deletes dictations right away: say how many first.</summary>
    bool ConfirmShorter(int count, int days)
    {
        var entries = App.Services.History.Entries;
        var gone = count > 0 ? Math.Max(0, entries.Count - count) : entries.Count(e => e.Time < DateTime.Now.AddDays(-days));
        if (gone == 0) return true;
        return MessageBox.Show($"This deletes {gone} older dictation{(gone == 1 ? "" : "s")} from History right away, with {(gone == 1 ? "its recording" : "their recordings")}. Go ahead?",
            AppInfo.Name, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes
            || RevertKeep();
    }

    bool RevertKeep()
    {
        var s = App.Services.Settings.Current;
        TextKeepBox.SelectedItem = TextKeepBox.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(i => i.Tag is (int c, int d) && c == s.HistoryLimit && d == s.HistoryDays);
        return false;
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

    void ResetWords_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("Reset the Analytics word tally (words, phrases, corrections, fillers, hours, profiles)? History and the dashboard counts are not touched.",
                AppInfo.Name, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        App.Services.Words.Clear();
    }

    void ResetUsage_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("Reset the dashboard's daily counts (words per day, streaks, apps)? History itself is not touched.",
                AppInfo.Name, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        App.Services.Usage.Clear();
    }
}
