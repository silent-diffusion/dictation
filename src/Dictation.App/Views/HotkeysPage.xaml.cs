using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Dictation.App.Services;

namespace Dictation.App.Views;

public partial class HotkeysPage : UserControl
{
    public HotkeysPage()
    {
        InitializeComponent();
        Refresh();
    }

    void Refresh()
    {
        var s = App.Services.Settings.Current;
        ToggleBox.Text = s.Hotkey;
        CycleBox.Text = string.IsNullOrEmpty(s.CycleProfileHotkey) ? "(none)" : s.CycleProfileHotkey;
        ShowStatus();
    }

    void ShowStatus()
    {
        var err = App.HotkeyError;
        StatusText.Text = err ?? "✓ Shortcuts are registered.";
        StatusText.Foreground = err == null ? System.Windows.Media.Brushes.SeaGreen : System.Windows.Media.Brushes.IndianRed;
    }

    void Box_Focus(object sender, KeyboardFocusChangedEventArgs e) { }

    static string? Capture(KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
            or Key.LWin or Key.RWin or Key.None or Key.ImeProcessed or Key.DeadCharProcessed) return null;
        var mods = Keyboard.Modifiers;
        var isFKey = key >= Key.F1 && key <= Key.F24;
        if (mods == ModifierKeys.None && !isFKey) return null;
        return HotkeyManager.Format(mods, key);
    }

    void Toggle_KeyDown(object sender, KeyEventArgs e)
    {
        var text = Capture(e);
        if (text == null) return;
        App.Services.Settings.Current.Hotkey = text;
        App.Services.Settings.Save();
        Refresh();
    }

    void Cycle_KeyDown(object sender, KeyEventArgs e)
    {
        var text = Capture(e);
        if (text == null) return;
        App.Services.Settings.Current.CycleProfileHotkey = text;
        App.Services.Settings.Save();
        Refresh();
    }

    void ResetToggle_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Settings.Current.Hotkey = "Ctrl+Space";
        App.Services.Settings.Save();
        Refresh();
    }

    void ClearCycle_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Settings.Current.CycleProfileHotkey = "";
        App.Services.Settings.Save();
        Refresh();
    }
}
