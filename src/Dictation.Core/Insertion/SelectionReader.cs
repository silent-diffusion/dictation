using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Insertion;

/// <summary>Reads the text selected in whatever app has focus, for Read aloud.</summary>
public static class SelectionReader
{
    const int MaxChars = 100_000;

    /// <summary>
    /// The selected text, or "" when nothing is selected. Asks the app through UI Automation first (no side effects);
    /// only when the app doesn't support that, copies the selection with Ctrl+C and puts the user's clipboard back.
    /// Call from the UI thread (the clipboard needs it).
    /// </summary>
    public static async Task<string> GetSelectedTextAsync()
    {
        var uia = await Task.Run(ReadViaAutomation).WaitAsync(TimeSpan.FromMilliseconds(600)).ContinueWith(
            t => t.IsCompletedSuccessfully ? t.Result : null, TaskScheduler.Default);
        if (uia != null) return uia; // the app answered: "" really means nothing is selected
        return await CopySelectionAsync();
    }

    /// <summary>null when the focused control doesn't expose text through UI Automation.</summary>
    static string? ReadViaAutomation()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused == null || !focused.TryGetCurrentPattern(TextPattern.Pattern, out var p)) return null;
            var pattern = (TextPattern)p;
            if (pattern.SupportedTextSelection == SupportedTextSelection.None) return null;
            var selection = pattern.GetSelection();
            return selection.Length == 0 ? "" : string.Concat(selection.Select(r => r.GetText(MaxChars))).Trim();
        }
        catch (Exception e)
        {
            Log.Info("Selection not readable via UI Automation: " + e.GetType().Name);
            return null;
        }
    }

    /// <summary>Ctrl+C, then restore the clipboard. "" if the app didn't copy anything (nothing selected).</summary>
    static async Task<string> CopySelectionAsync()
    {
        // The Read aloud hotkey's own Ctrl/Shift may still be held; Ctrl+Shift+C means something else in many apps.
        await TextInserter.WaitForModifiersReleasedAsync(CancellationToken.None);
        var before = Native.GetClipboardSequenceNumber();
        var snapshot = ClipboardSnapshot.Capture();
        Native.Send(new[]
        {
            Native.Key(Native.VK_CONTROL, 0, 0), Native.Key(Native.VK_C, 0, 0),
            Native.Key(Native.VK_C, 0, Native.KEYEVENTF_KEYUP), Native.Key(Native.VK_CONTROL, 0, Native.KEYEVENTF_KEYUP),
        });
        for (var i = 0; i < 20 && Native.GetClipboardSequenceNumber() == before; i++) await Task.Delay(25);
        if (Native.GetClipboardSequenceNumber() == before) return "";
        await Task.Delay(30); // let the app finish writing all formats
        var text = "";
        try { ClipboardSnapshot.Retry(() => text = Clipboard.ContainsText() ? Clipboard.GetText() : ""); }
        catch (Exception e) { Log.Warn("Could not read the copied selection: " + e.Message); }
        snapshot?.Restore();
        return text.Trim();
    }

    /// <summary>Text currently on the clipboard, or "".</summary>
    public static string ClipboardText()
    {
        try
        {
            var text = "";
            ClipboardSnapshot.Retry(() => text = Clipboard.ContainsText() ? Clipboard.GetText() : "");
            return text.Trim();
        }
        catch { return ""; }
    }
}
