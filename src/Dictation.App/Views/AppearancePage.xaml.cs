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
        foreach (var cell in PositionGrid.Children.OfType<RadioButton>())
            if ((string)cell.Tag == s.OverlayPosition.ToString()) cell.IsChecked = true;
        PositionName.Text = Describe(s.OverlayPosition);
        UpdateSystemHint();
        AutoSave.Hook(this, () => App.Services.Settings.Save());
    }

    void UpdateSystemHint() =>
        SystemHint.Text = App.Services.Settings.Current.Theme == AppTheme.System
            ? (ThemeManager.IsDark ? "Dark right now" : "Light right now")
            : " ";

    /// <summary>"BottomCenter" → "Bottom center".</summary>
    internal static string Describe(OverlayPosition p)
    {
        if (p == OverlayPosition.Center) return "Center of the screen";
        var words = System.Text.RegularExpressions.Regex.Replace(p.ToString(), "(?<=[a-z])(?=[A-Z])", " ").ToLowerInvariant();
        return char.ToUpper(words[0]) + words[1..];
    }

    void Position_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded || sender is not RadioButton { Tag: string tag } || !Enum.TryParse<OverlayPosition>(tag, out var pos)) return;
        App.Services.Settings.Current.OverlayPosition = pos;
        App.Services.Settings.Save();
        PositionName.Text = Describe(pos);
        ((App)Application.Current).PreviewOverlay(); // show the pill where it will now appear
    }

    void Theme_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return; // the initial selection in the constructor
        var s = App.Services.Settings.Current;
        s.Theme = sender == LightRadio ? AppTheme.Light : sender == DarkRadio ? AppTheme.Dark : AppTheme.System;
        App.Services.Settings.Save(); // applies the theme right away (App.OnSettingsChanged)
        UpdateSystemHint();
    }
}
