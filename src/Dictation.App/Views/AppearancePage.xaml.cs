using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
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
        UpdateSystemHint();
        BuildSchemePicker();
        AutoSave.Hook(this, () => App.Services.Settings.Save());
    }

    // ----- accent colors (the setting keeps its old name, ColorScheme) -----

    void BuildSchemePicker()
    {
        var s = App.Services.Settings.Current;
        foreach (var scheme in Enum.GetValues<ColorScheme>())
        {
            var (light, dark) = ColorSchemes.Accent(scheme);
            // The accent on light paper and on dark paper, as two squares
            var swatches = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4, 4, 0, 0) };
            foreach (var (hex, paper) in new[] { (light, "#E8E7E3"), (dark, "#0E0E0D") })
                swatches.Children.Add(new Border
                {
                    Width = 22, Height = 22, Margin = new Thickness(0, 0, 4, 0), Padding = new Thickness(5),
                    Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(paper)),
                    BorderBrush = new SolidColorBrush(Color.FromArgb(0x55, 0x80, 0x80, 0x80)), BorderThickness = new Thickness(1),
                    Child = new Border { Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)) },
                });
            var content = new StackPanel();
            content.Children.Add(swatches);
            content.Children.Add(new TextBlock
            {
                Text = ColorSchemes.Name(scheme).ToUpper(), Margin = new Thickness(4, 10, 0, 2), FontSize = 11, FontWeight = FontWeights.Bold,
                FontFamily = (FontFamily)FindResource("Ob.Mono"),
            });
            var card = new RadioButton
            {
                GroupName = "Scheme", Style = (Style)FindResource("ChoiceCard"), Content = content,
                Margin = new Thickness(scheme == ColorScheme.Ember ? 0 : 4, 0, scheme == ColorScheme.Rose ? 0 : 4, 0),
                IsChecked = s.ColorScheme == scheme,
            };
            System.Windows.Automation.AutomationProperties.SetName(card, ColorSchemes.Name(scheme));
            card.Checked += (_, _) =>
            {
                if (!IsLoaded) return;
                App.Services.Settings.Current.ColorScheme = scheme;
                App.Services.Settings.Save(); // applies right away (App.OnSettingsChanged)
            };
            SchemeGrid.Children.Add(card);
        }
    }

    void UpdateSystemHint() =>
        SystemHint.Text = App.Services.Settings.Current.Theme == AppTheme.System
            ? (ThemeManager.IsDark ? "DARK RIGHT NOW" : "LIGHT RIGHT NOW")
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
