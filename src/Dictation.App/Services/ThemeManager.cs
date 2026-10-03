using System.Windows;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Microsoft.Win32;

namespace Dictation.App.Services;

/// <summary>
/// Applies the Light or Dark look: the Fluent control theme plus our own palette (Themes\Light.xaml or Dark.xaml).
/// In System mode it follows the Windows "app mode" setting and updates when the user changes it.
/// </summary>
public static class ThemeManager
{
    static ResourceDictionary? _palette;
    static AppTheme _theme;
    static bool _listening;

    public static bool IsDark { get; private set; }

    public static void Apply(AppTheme theme)
    {
        _theme = theme;
        var dark = theme switch
        {
            AppTheme.Light => false,
            AppTheme.Dark => true,
            _ => SystemUsesDarkApps(),
        };
        if (_palette != null && dark == IsDark) return;
        IsDark = dark;

        var app = Application.Current;
        app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
        var palette = new ResourceDictionary
        {
            Source = new Uri($"pack://application:,,,/Themes/{(dark ? "Dark" : "Light")}.xaml", UriKind.Absolute),
        };
        if (_palette != null) app.Resources.MergedDictionaries.Remove(_palette);
        app.Resources.MergedDictionaries.Add(palette);
        _palette = palette;

        if (!_listening)
        {
            _listening = true;
            SystemEvents.UserPreferenceChanged += (_, e) =>
            {
                if (e.Category == UserPreferenceCategory.General && _theme == AppTheme.System)
                    app.Dispatcher.BeginInvoke(() => Apply(AppTheme.System));
            };
        }
    }

    /// <summary>Windows Settings > Personalization > Colors > "Choose your default app mode".</summary>
    static bool SystemUsesDarkApps()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch (Exception e)
        {
            Log.Warn("Could not read the Windows app theme: " + e.Message);
            return false;
        }
    }
}
