using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Insertion;

/// <summary>What was known, when a dictation started, about where its text should go.</summary>
public enum PasteSpotKind
{
    /// <summary>A text field with its caret position: the text goes back to exactly that spot.</summary>
    Caret,
    /// <summary>An app window whose caret Windows can't tell us (terminals, many Electron apps): the window is brought
    /// back and the text pasted at its caret, as before.</summary>
    Window,
    /// <summary>Nothing to type into: the desktop, the taskbar, or a button or list had focus. The user is asked.</summary>
    None,
}

/// <summary>
/// Where the cursor was when a dictation started. The text goes back there even if the user has clicked elsewhere
/// meanwhile, in that app or another: the window is brought to the front, the same control focused and the caret put
/// back where it was (through UI Automation) before pasting. Apps that don't show their caret to UI Automation get
/// the window only, as before.
/// </summary>
public sealed class PasteSpot
{
    public PasteSpotKind Kind { get; }
    readonly AutomationElement? _element;
    readonly TextPatternRange? _caret;

    PasteSpot(PasteSpotKind kind, AutomationElement? element = null, TextPatternRange? caret = null)
    {
        Kind = kind; _element = element; _caret = caret;
    }

    public static readonly PasteSpot Unknown = new(PasteSpotKind.Window);

    /// <summary>Windows that are never somewhere to type: the desktop, the taskbar, the Start menu and search.</summary>
    static readonly HashSet<string> ShellClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland",
    };
    static readonly HashSet<string> ShellProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "StartMenuExperienceHost", "SearchHost", "SearchApp", "ShellExperienceHost",
    };

    /// <summary>Controls that hold no caret: focused, they mean nothing to type into was selected.</summary>
    static readonly HashSet<ControlType> NonText = new()
    {
        ControlType.Button, ControlType.CheckBox, ControlType.RadioButton, ControlType.ListItem, ControlType.List,
        ControlType.Tree, ControlType.TreeItem, ControlType.Menu, ControlType.MenuItem, ControlType.MenuBar, ControlType.Tab,
        ControlType.TabItem, ControlType.Hyperlink, ControlType.Image, ControlType.ScrollBar, ControlType.Slider,
        ControlType.TitleBar, ControlType.ToolBar, ControlType.Header, ControlType.HeaderItem, ControlType.SplitButton,
        ControlType.Thumb, ControlType.DataItem, ControlType.Calendar,
    };

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);

    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int key);

    /// <summary>A window that is never somewhere to type (or no window at all). Quick: no UI Automation.</summary>
    public static bool IsNowhere(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !Native.IsWindow(hwnd)) return true;
        var sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        if (ShellClasses.Contains(sb.ToString())) return true;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        try { return ShellProcesses.Contains(Process.GetProcessById((int)pid).ProcessName); }
        catch { return false; }
    }

    /// <summary>A mouse button is held (the user is still clicking).</summary>
    public static bool MouseDown => (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0;

    /// <summary>Where the text should go, read while <paramref name="target"/> still has focus. Never throws.</summary>
    public static async Task<PasteSpot> CaptureAsync(InsertionTarget target, TimeSpan timeout)
    {
        if (IsNowhere(target.Hwnd)) return new PasteSpot(PasteSpotKind.None);
        var read = Task.Run(Read);
        return await Task.WhenAny(read, Task.Delay(timeout)) == read ? read.Result : Unknown;
    }

    static PasteSpot Read()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused == null) return Unknown;
            if (focused.TryGetCurrentPattern(TextPattern.Pattern, out var p))
            {
                var selection = ((TextPattern)p).GetSelection();
                if (selection.Length > 0) return new PasteSpot(PasteSpotKind.Caret, focused, selection[0].Clone());
            }
            if (NonText.Contains(focused.Current.ControlType)) return new PasteSpot(PasteSpotKind.None);
            return Unknown;
        }
        catch (Exception e)
        {
            Log.Info("Couldn't read where the cursor is: " + e.GetType().Name);
            return Unknown;
        }
    }

    /// <summary>
    /// Put the caret back where it was, in its own control (the window must already be in front). True when it is
    /// there now; false when the app wouldn't take it (the text then goes wherever the caret is, as before).
    /// </summary>
    public async Task<bool> RestoreAsync(TimeSpan timeout)
    {
        if (Kind != PasteSpotKind.Caret || _element == null || _caret == null) return false;
        var work = Task.Run(() =>
        {
            try
            {
                var pattern = (TextPattern)_element.GetCurrentPattern(TextPattern.Pattern);
                if (Same(pattern) && Automation.Compare(AutomationElement.FocusedElement, _element)) return true; // still there
                try { _element.SetFocus(); } catch (Exception e) { Log.Info("Couldn't refocus the dictation's text field: " + e.GetType().Name); }
                _caret.Select();
                return Same(pattern);
            }
            catch (Exception e)
            {
                Log.Info("Couldn't put the caret back: " + e.GetType().Name);
                return false;
            }
        });
        var ok = await Task.WhenAny(work, Task.Delay(timeout)) == work && work.Result;
        Log.Info(ok ? "Pasting at the cursor position the dictation started at" : "The cursor position couldn't be restored; pasting at the current caret");
        return ok;
    }

    bool Same(TextPattern pattern)
    {
        var now = pattern.GetSelection();
        return now.Length > 0 &&
               now[0].CompareEndpoints(TextPatternRangeEndpoint.Start, _caret!, TextPatternRangeEndpoint.Start) == 0 &&
               now[0].CompareEndpoints(TextPatternRangeEndpoint.End, _caret!, TextPatternRangeEndpoint.End) == 0;
    }
}
