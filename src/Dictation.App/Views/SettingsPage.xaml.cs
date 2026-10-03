using System.Windows.Controls;

namespace Dictation.App.Views;

/// <summary>All app settings in one place, grouped into sections, so the main sidebar only holds profiles.</summary>
public partial class SettingsPage : UserControl
{
    public SettingsPage(string section = "General")
    {
        InitializeComponent();
        Show(section);
    }

    /// <summary>Open a section by its tag (General, Hotkeys, Audio, Speech, Models, Appearance, Advanced, About).</summary>
    public void Show(string section)
    {
        foreach (var item in Nav.Items.OfType<ListBoxItem>())
            if (item.Tag as string == section) { Nav.SelectedItem = item; return; }
    }

    void Nav_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Nav.SelectedItem is not ListBoxItem { Tag: string tag }) return;
        Host.Content = tag switch
        {
            "Hotkeys" => new HotkeysPage(),
            "Audio" => new AudioPage(),
            "Speech" => new SpeechPage(),
            "Models" => new ModelsPage(),
            "Appearance" => new AppearancePage(),
            "Advanced" => new AdvancedPage(),
            "About" => new AboutPage(),
            _ => (object)new GeneralPage(),
        };
    }
}
