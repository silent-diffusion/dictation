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
    static ResourceDictionary? _palette, _scheme;
    static AppTheme _theme;
    static ColorScheme _colors;
    static bool _listening;

    public static bool IsDark { get; private set; }

    public static void Apply(AppTheme theme, ColorScheme colors = ColorScheme.Ember)
    {
        _theme = theme;
        var dark = theme switch
        {
            AppTheme.Light => false,
            AppTheme.Dark => true,
            _ => SystemUsesDarkApps(),
        };
        if (_palette != null && dark == IsDark && colors == _colors) return;
        IsDark = dark;
        _colors = colors;

        var app = Application.Current;
        app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
        var palette = new ResourceDictionary
        {
            Source = new Uri($"pack://application:,,,/Themes/{(dark ? "Dark" : "Light")}.xaml", UriKind.Absolute),
        };
        if (_palette != null) app.Resources.MergedDictionaries.Remove(_palette);
        if (_scheme != null) app.Resources.MergedDictionaries.Remove(_scheme);
        app.Resources.MergedDictionaries.Add(palette);
        _palette = palette;
        // The accent goes on top: later dictionaries win, so it only replaces the colors it names.
        _scheme = ColorSchemes.Build(colors, dark);
        app.Resources.MergedDictionaries.Add(_scheme);

        if (!_listening)
        {
            _listening = true;
            SystemEvents.UserPreferenceChanged += (_, e) =>
            {
                if (e.Category == UserPreferenceCategory.General && _theme == AppTheme.System)
                    app.Dispatcher.BeginInvoke(() => Apply(AppTheme.System, _colors));
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

/// <summary>
/// The accent colors. Oberton is ink on paper; the accent marks what is live or matters most right now (today's count, a
/// countdown, the word being read, words the AI added, errors). Red is never an accent: it means recording.
/// The setting keeps its old name and values (<see cref="ColorScheme"/>) so saved settings load: each former color
/// scheme maps to the accent closest to it, and Ember, the old red default, becomes Cobalt.
/// </summary>
public static class ColorSchemes
{
    /// <summary>The name shown in the picker.</summary>
    public static string Name(ColorScheme c) => c switch
    {
        ColorScheme.Ocean => "Teal",
        ColorScheme.Forest => "Signal green",
        ColorScheme.Violet => "Violet",
        ColorScheme.Rose => "Amber",
        _ => "Cobalt",
    };

    /// <summary>The accent (on light paper, on dark paper).</summary>
    public static (string Light, string Dark) Accent(ColorScheme c) => c switch
    {
        ColorScheme.Ocean => ("#00747C", "#3CD2D9"),
        ColorScheme.Forest => ("#00875A", "#3BE0A2"),
        ColorScheme.Violet => ("#6A2CF5", "#B39BFF"),
        ColorScheme.Rose => ("#9A6500", "#FFC233"),
        _ => ("#2340FF", "#7F8DFF"),
    };

    /// <summary>The keys that take the accent. Ob.AccentOnDark is the dark-paper version in both themes, for the
    /// overlay and the Read aloud player, which are always dark.</summary>
    static readonly string[] Keys = { "Ob.Accent", "Ob.Busy", "Ob.Error", "Ob.DiffAdded" };

    /// <summary>The accent's brushes for light or dark mode, laid over the palette.</summary>
    public static ResourceDictionary Build(ColorScheme c, bool dark)
    {
        var (light, darkHex) = Accent(c);
        var d = new ResourceDictionary();
        foreach (var key in Keys) d[key] = Brush(dark ? darkHex : light);
        d["Ob.AccentOnDark"] = Brush(darkHex);
        return d;
    }

    static System.Windows.Media.SolidColorBrush Brush(string hex)
    {
        var brush = new System.Windows.Media.SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        return brush;
    }
}
