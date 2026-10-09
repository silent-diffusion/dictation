using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Settings;

namespace Dictation.App.Views;

/// <summary>Dictation: the profiles (how your words are cleaned up), each with its own page.</summary>
public partial class SpeechToTextPage : UserControl
{
    public SpeechToTextPage()
    {
        InitializeComponent();
        var s = App.Services;
        var st = s.Settings.Current;
        HotkeyHint.Text = $"Press {st.Hotkey} in any app to dictate, and again to stop. The active profile decides what happens to your words.";
        CycleHint.Text = string.IsNullOrEmpty(st.CycleProfileHotkey) ? "" : (st.CycleProfileHotkey + " cycles").ToUpperInvariant();
        ProfileList.ItemsSource = s.Profiles.Profiles;
        ProfileList.SelectedItem = s.Profiles.Active;
        s.Profiles.Profiles.CollectionChanged += OnProfilesChanged;
        Unloaded += (_, _) => s.Profiles.Profiles.CollectionChanged -= OnProfilesChanged;
    }

    void OnProfilesChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (ProfileList.SelectedItem == null) ProfileList.SelectedItem = App.Services.Profiles.Active;
    }

    public void Select(Profile p) => ProfileList.SelectedItem = p;

    void ProfileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProfileList.SelectedItem is Profile p) Host.Content = new ProfilePage(p);
    }

    void NewProfile_Click(object sender, RoutedEventArgs e) => ProfileList.SelectedItem = App.Services.Profiles.Create();

}
