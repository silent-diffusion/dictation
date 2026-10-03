using System.Windows;
using System.Windows.Controls;
using Dictation.App.Services;
using Dictation.Core.Settings;

namespace Dictation.App.Views;

public partial class AppearancePage : UserControl
{
    public AppearancePage()
    {
        InitializeComponent();
        var s = App.Services.Settings.Current;
        DataContext = s;
        (s.Theme switch { AppTheme.Light => LightRadio, AppTheme.Dark => DarkRadio, _ => SystemRadio }).IsChecked = true;
        PreviewProfile.Text = App.Services.Profiles.Active.Name;
        UpdateSystemHint();
        AutoSave.Hook(this, () => App.Services.Settings.Save());
    }

    void UpdateSystemHint() =>
        SystemHint.Text = App.Services.Settings.Current.Theme == AppTheme.System
            ? (ThemeManager.IsDark ? "Dark right now" : "Light right now")
            : " ";

    void Theme_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return; // the initial selection in the constructor
        var s = App.Services.Settings.Current;
        s.Theme = sender == LightRadio ? AppTheme.Light : sender == DarkRadio ? AppTheme.Dark : AppTheme.System;
        App.Services.Settings.Save(); // applies the theme right away (App.OnSettingsChanged)
        UpdateSystemHint();
    }
}
