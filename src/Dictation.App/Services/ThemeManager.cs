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
        // The color scheme goes on top: later dictionaries win, so it only replaces the colors it names.
        _scheme = ColorSchemes.Build(colors, dark);
        if (_scheme != null) app.Resources.MergedDictionaries.Add(_scheme);

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
/// The color schemes. Each replaces the background tints, outlines and accent of the Light and Dark palettes with a
/// version of the same lightness, so text keeps its contrast (the text colors themselves are never replaced).
/// </summary>
public static class ColorSchemes
{
    /// <summary>The accent of each scheme (light, dark), for the picker's swatches.</summary>
    public static (string Light, string Dark) Accent(ColorScheme c) => c switch
    {
        ColorScheme.Ocean => ("#1F6FD1", "#4C9AFF"),
        ColorScheme.Forest => ("#23845A", "#4FBF7F"),
        ColorScheme.Violet => ("#6C47E0", "#9C82FF"),
        ColorScheme.Rose => ("#C2255C", "#F06595"),
        _ => ("#D9381E", "#E5533A"),
    };

    static readonly string[] Keys =
        { "Ob.Window", "Ob.Sidebar", "Ob.Border", "Ob.Divider", "Ob.Subtle", "Ob.Hover", "Ob.Selected", "Ob.Track", "Ob.Mark", "Ob.Strong", "Ob.Record", "Ob.DiffAdded", "Ob.Card" };

    // Per scheme, light then dark, in the order of Keys. Ob.Strong in dark mode stays the light text color (null).
    static string?[]? Colors(ColorScheme c, bool dark) => (c, dark) switch
    {
        (ColorScheme.Ocean, false) => new string?[] { "#F3F6F9", "#E8EEF4", "#D5DEE8", "#E3E9F0", "#DFE6EE", "#DFE6EE", "#FFFFFF", "#C3CFDC", "#14212E", "#14212E", "#1F6FD1", "#1A5FB4", null },
        (ColorScheme.Ocean, true) => new string?[] { "#15191E", "#0F1317", "#2E3742", "#252C34", "#252C34", "#1F262E", "#27303A", "#3E4955", "#27303A", null, "#4C9AFF", "#8CBEFF", "#1D232A" },
        (ColorScheme.Forest, false) => new string?[] { "#F4F7F3", "#EAEFE8", "#D6DED3", "#E4EAE2", "#DFE6DC", "#DFE6DC", "#FFFFFF", "#C4CFC0", "#15241B", "#15241B", "#23845A", "#1E6E4A", null },
        (ColorScheme.Forest, true) => new string?[] { "#151916", "#0F1310", "#2D3830", "#242C26", "#242C26", "#1E2620", "#26302A", "#3D4A40", "#26302A", null, "#4FBF7F", "#8FD9AE", "#1C231E" },
        (ColorScheme.Violet, false) => new string?[] { "#F6F4F9", "#EDE9F3", "#DCD5E6", "#E8E3EF", "#E3DDEC", "#E3DDEC", "#FFFFFF", "#CBC2D8", "#1E162B", "#1E162B", "#6C47E0", "#5F3DC4", null },
        (ColorScheme.Violet, true) => new string?[] { "#18161D", "#121016", "#353041", "#2A2632", "#2A2632", "#231F2A", "#2D2836", "#474052", "#2D2836", null, "#9C82FF", "#C3B3FF", "#211E28" },
        (ColorScheme.Rose, false) => new string?[] { "#FAF4F5", "#F2E8EA", "#E7D6DA", "#EFE3E6", "#EADDE0", "#EADDE0", "#FFFFFF", "#D6C1C6", "#2B1219", "#2B1219", "#C2255C", "#A61E4D", null },
        (ColorScheme.Rose, true) => new string?[] { "#1B1618", "#141012", "#3B3035", "#2E2629", "#2E2629", "#261F22", "#30282C", "#4D4147", "#30282C", null, "#F06595", "#FAA2C1", "#251E21" },
        _ => null, // Ember: the palettes as they are
    };

    /// <summary>The overrides for a scheme in light or dark mode; null for Ember (nothing to override).</summary>
    public static ResourceDictionary? Build(ColorScheme c, bool dark)
    {
        var colors = Colors(c, dark);
        if (colors == null) return null;
        var d = new ResourceDictionary();
        for (var i = 0; i < Keys.Length; i++)
        {
            if (colors[i] is not { } hex) continue;
            var brush = new System.Windows.Media.SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));
            brush.Freeze();
            d[Keys[i]] = brush;
        }
        return d;
    }
}
