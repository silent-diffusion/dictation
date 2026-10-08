using System.Windows;
using System.Windows.Controls;

namespace Dictation.App.Views;

/// <summary>All app settings in one place, in collapsible groups of sections.</summary>
public partial class SettingsPage : UserControl
{
    bool _switching;

    /// <summary>The section shown (its tag).</summary>
    public string Section { get; private set; } = "General";
    /// <summary>Another section was opened (for Back).</summary>
    public event Action<string>? SectionShown;

    public SettingsPage(string section = "General")
    {
        InitializeComponent();
        var collapsed = App.Services.Settings.Current.CollapsedSettingsGroups;
        foreach (var g in GroupList) g.IsExpanded = !collapsed.Contains(g.Name);
        Show(section);
    }

    IEnumerable<Expander> GroupList => Groups.Children.OfType<Expander>();
    static ListBox ListOf(Expander g) => (ListBox)g.Content;

    /// <summary>Open a section by its tag (General, Hotkeys, Audio, HistorySettings, Models, Speech, Cloud, Unloading,
    /// Appearance, Advanced, About), expanding its group if it was collapsed.</summary>
    public void Show(string section)
    {
        foreach (var g in GroupList)
            foreach (var item in ListOf(g).Items.OfType<ListBoxItem>())
                if (item.Tag as string == section)
                {
                    g.IsExpanded = true;
                    ListOf(g).SelectedItem = item;
                    return;
                }
    }

    void Nav_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_switching || sender is not ListBox list || list.SelectedItem is not ListBoxItem { Tag: string tag }) return;
        // One section is selected at a time, across all the groups.
        _switching = true;
        foreach (var g in GroupList) if (ListOf(g) != list) ListOf(g).SelectedItem = null;
        _switching = false;
        Section = tag;
        SectionShown?.Invoke(tag);
        Host.Content = tag switch
        {
            "Hotkeys" => new HotkeysPage(),
            "Audio" => new AudioPage(),
            "Speech" => new SpeechPage(),
            "HistorySettings" => new HistorySettingsPage(),
            "Models" => new ModelsPage(),
            "Cloud" => new CloudPage(),
            "Unloading" => new UnloadingPage(),
            "Appearance" => new AppearancePage(),
            "Advanced" => new AdvancedPage(),
            "About" => new AboutPage(),
            _ => (object)new GeneralPage(),
        };
    }

    /// <summary>Remember which groups are folded away.</summary>
    void Group_Toggled(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded || sender is not Expander g) return;
        var collapsed = App.Services.Settings.Current.CollapsedSettingsGroups;
        collapsed.Remove(g.Name);
        if (!g.IsExpanded) collapsed.Add(g.Name);
        App.Services.Settings.Save();
    }

}
