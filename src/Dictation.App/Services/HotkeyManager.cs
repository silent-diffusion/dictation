using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using Dictation.Core.Insertion;

namespace Dictation.App.Services;

/// <summary>System-wide hotkeys via RegisterHotKey on a hidden message-only window.</summary>
public sealed class HotkeyManager : IDisposable
{
    readonly HwndSource _source;
    readonly Dictionary<int, Action> _actions = new();

    public HotkeyManager()
    {
        var p = new HwndSourceParameters("DictationHotkeys") { ParentWindow = new IntPtr(-3) /* HWND_MESSAGE */, Width = 0, Height = 0 };
        _source = new HwndSource(p);
        _source.AddHook(Hook);
    }

    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && _actions.TryGetValue(wParam.ToInt32(), out var a))
        {
            handled = true;
            a();
        }
        return IntPtr.Zero;
    }

    /// <summary>Returns null on success, otherwise a user-readable error.</summary>
    public string? Register(int id, string text, Action action)
    {
        Unregister(id);
        if (string.IsNullOrWhiteSpace(text)) return null; // intentionally unset
        if (!TryParse(text, out var mods, out var vk)) return $"'{text}' isn't a valid shortcut.";
        if (!Native.RegisterHotKey(_source.Handle, id, mods | Native.MOD_NOREPEAT, vk))
        {
            var err = Marshal.GetLastWin32Error();
            return err == 1409
                ? $"{text} is already used by another application. Choose a different shortcut under Settings > Hotkeys."
                : $"Windows refused the shortcut {text} (error {err}).";
        }
        _actions[id] = action;
        return null;
    }

    public void Unregister(int id)
    {
        if (_actions.Remove(id)) Native.UnregisterHotKey(_source.Handle, id);
    }

    public static bool TryParse(string text, out uint mods, out uint vk)
    {
        mods = 0; vk = 0;
        Key? key = null;
        foreach (var raw in text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl" or "control": mods |= Native.MOD_CONTROL; break;
                case "alt": mods |= Native.MOD_ALT; break;
                case "shift": mods |= Native.MOD_SHIFT; break;
                case "win" or "windows": mods |= Native.MOD_WIN; break;
                default:
                    if (!Enum.TryParse<Key>(raw, true, out var k)) return false;
                    key = k; break;
            }
        }
        if (key == null) return false;
        vk = (uint)KeyInterop.VirtualKeyFromKey(key.Value);
        return vk != 0;
    }

    public static string Format(ModifierKeys mods, Key key)
    {
        var parts = new List<string>();
        if (mods.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (mods.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (mods.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (mods.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(key.ToString());
        return string.Join("+", parts);
    }

    public void Dispose()
    {
        foreach (var id in _actions.Keys.ToList()) Native.UnregisterHotKey(_source.Handle, id);
        _actions.Clear();
        _source.Dispose();
    }
}
