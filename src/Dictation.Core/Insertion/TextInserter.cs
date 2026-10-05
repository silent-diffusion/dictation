using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;

namespace Dictation.Core.Insertion;

/// <summary>The window that had focus when dictation began.</summary>
public sealed record InsertionTarget(IntPtr Hwnd, uint ProcessId, string ProcessName, string Title)
{
    public static InsertionTarget Capture()
    {
        var h = Native.GetForegroundWindow();
        Native.GetWindowThreadProcessId(h, out var pid);
        var name = "";
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch { }
        var sb = new StringBuilder(256);
        Native.GetWindowText(h, sb, sb.Capacity);
        return new InsertionTarget(h, pid, name, sb.ToString());
    }

    public bool IsAlive => Hwnd != IntPtr.Zero && Native.IsWindow(Hwnd);
}

/// <summary>One way of getting text into another application. Throw on failure so the caller can fall back.</summary>
public interface ITextInsertionStrategy
{
    string Name { get; }
    Task InsertAsync(string text, InsertionTarget target, CancellationToken ct);
}

/// <summary>Types the text as Unicode keystrokes. Doesn't touch the clipboard. Best for short single-line text.</summary>
public sealed class UnicodeTypingStrategy : ITextInsertionStrategy
{
    public string Name => "Typing";

    public async Task InsertAsync(string text, InsertionTarget target, CancellationToken ct)
    {
        // Chromium/Electron apps (browsers, Claude, Slack, VS Code) drop or repeat characters when flooded with
        // injected keystrokes, so send a few characters at a time and give the target time to process them.
        const int batch = 4;
        for (var i = 0; i < text.Length;)
        {
            ct.ThrowIfCancellationRequested();
            var n = Math.Min(batch, text.Length - i);
            if (i + n < text.Length && char.IsHighSurrogate(text[i + n - 1])) n++; // never split a surrogate pair
            var inputs = new Native.INPUT[n * 2];
            for (var k = 0; k < n; k++)
            {
                inputs[k * 2] = Native.Key(0, text[i + k], Native.KEYEVENTF_UNICODE);
                inputs[k * 2 + 1] = Native.Key(0, text[i + k], Native.KEYEVENTF_UNICODE | Native.KEYEVENTF_KEYUP);
            }
            var sent = Native.Send(inputs);
            if (sent != inputs.Length)
                throw new InvalidOperationException($"SendInput injected {sent}/{inputs.Length} events (Win32 error {Marshal.GetLastWin32Error()}). " +
                                                    "The target may be running as administrator.");
            i += n;
            if (i < text.Length) await Task.Delay(10, ct);
        }
    }
}
/// <summary>Puts the text on the clipboard, sends Ctrl+V, then restores the user's previous clipboard.</summary>
public sealed class ClipboardPasteStrategy : ITextInsertionStrategy
{
    public string Name => "Clipboard";

    public async Task InsertAsync(string text, InsertionTarget target, CancellationToken ct)
    {
        var snapshot = ClipboardSnapshot.Capture();
        try
        {
            var data = new DataObject();
            data.SetText(text, TextDataFormat.UnicodeText);
            // Keep our temporary text out of Windows clipboard history and cloud sync.
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
            data.SetData("CanIncludeInClipboardHistory", new MemoryStream(new byte[4]));
            data.SetData("CanUploadToCloudClipboard", new MemoryStream(new byte[4]));
            ClipboardSnapshot.Retry(() => Clipboard.SetDataObject(data, true));

            var ok = Native.Send(new[]
            {
                Native.Key(Native.VK_CONTROL, 0, 0),
                Native.Key(Native.VK_V, 0, 0),
                Native.Key(Native.VK_V, 0, Native.KEYEVENTF_KEYUP),
                Native.Key(Native.VK_CONTROL, 0, Native.KEYEVENTF_KEYUP),
            });
            if (ok != 4) throw new InvalidOperationException("SendInput for Ctrl+V failed (target may be running as administrator).");
            await Task.Delay(Math.Min(1200, 350 + text.Length / 20), ct); // let the target read the clipboard first
        }
        finally
        {
            snapshot?.Restore();
        }
    }
}

/// <summary>Best-effort copy of everything on the clipboard so it can be put back afterwards.</summary>
public sealed class ClipboardSnapshot
{
    sealed record Item(string Format, object Value);
    readonly List<Item> _items = new();

    public static void Retry(Action a)
    {
        for (var i = 0; ; i++)
        {
            try { a(); return; }
            catch (COMException) when (i < 8) { Thread.Sleep(30); }
        }
    }

    public static ClipboardSnapshot? Capture()
    {
        try
        {
            var snap = new ClipboardSnapshot();
            IDataObject? d = null;
            Retry(() => d = Clipboard.GetDataObject());
            if (d == null) return snap;
            foreach (var fmt in d.GetFormats(false))
            {
                try
                {
                    var v = d.GetData(fmt, false);
                    if (v is MemoryStream ms) v = ms.ToArray();
                    if (v != null) snap._items.Add(new Item(fmt, v));
                }
                catch { /* some formats (delayed rendering) can't be read; skip them */ }
            }
            return snap;
        }
        catch (Exception e)
        {
            Log.Warn("Could not snapshot clipboard: " + e.Message);
            return null;
        }
    }

    public void Restore()
    {
        try
        {
            if (_items.Count == 0) { Retry(Clipboard.Clear); return; }
            var d = new DataObject();
            foreach (var it in _items)
            {
                try { d.SetData(it.Format, it.Value is byte[] b ? new MemoryStream(b) : it.Value, false); } catch { }
            }
            Retry(() => Clipboard.SetDataObject(d, true));
        }
        catch (Exception e) { Log.Warn("Could not restore clipboard: " + e.Message); }
    }
}

/// <summary>Picks a strategy per application/text, brings the original window back, and inserts.</summary>
public sealed class TextInserter
{
    readonly SettingsService _settings;
    readonly UnicodeTypingStrategy _typing = new();
    readonly ClipboardPasteStrategy _paste = new();

    public TextInserter(SettingsService settings) => _settings = settings;

    public async Task InsertAsync(string text, InsertionTarget target, CancellationToken ct = default)
    {
        if (!target.IsAlive)
            throw new UserFacingException("The window you were dictating into was closed.");

        await WaitForModifiersReleasedAsync(ct);
        if (!await EnsureForegroundAsync(target, ct))
            throw new UserFacingException("Couldn't switch back to the app you were typing in. Click into it and try again.");
        await Task.Delay(40, ct);

        var s = _settings.Current;
        var mode = s.AppOverrides.TryGetValue(target.ProcessName, out var o) ? o : s.Insertion;
        // Auto = paste: one atomic operation, reliable in every kind of app. Typing is a fallback (or a per-app choice).
        if (mode == InsertionMode.Auto) mode = InsertionMode.Clipboard;

        ITextInsertionStrategy primary = mode == InsertionMode.Clipboard ? _paste : _typing;
        ITextInsertionStrategy fallback = mode == InsertionMode.Clipboard ? _typing : _paste;
        if (primary == _typing && text.Contains('\n')) primary = _paste; // Enter would submit chat boxes; paste keeps breaks intact

        try
        {
            await primary.InsertAsync(text, target, ct);
            Log.Info($"Inserted {text.Length} chars into {target.ProcessName} via {primary.Name}");
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Log.Warn($"{primary.Name} insertion failed ({e.Message}); trying {fallback.Name}");
            if (fallback == _typing && text.Contains('\n'))
                throw new UserFacingException("Text could not be inserted into that application.", e);
            try
            {
                await fallback.InsertAsync(text, target, ct);
                Log.Info($"Inserted {text.Length} chars into {target.ProcessName} via {fallback.Name} (fallback)");
            }
            catch (Exception e2) when (e2 is not OperationCanceledException)
            {
                throw new UserFacingException(
                    "Text could not be inserted. If that app runs as administrator, run this app as administrator too.", e2);
            }
        }
    }

    /// <summary>Bring the dictation target back to the front (it normally still is).</summary>
    public async Task<bool> FocusAsync(InsertionTarget target, CancellationToken ct = default)
    {
        if (!target.IsAlive) return false;
        await WaitForModifiersReleasedAsync(ct);
        return await EnsureForegroundAsync(target, ct);
    }

    /// <summary>
    /// Type a short piece straight into the target, keystroke by keystroke (no clipboard), for text that streams in
    /// as it is heard. Pieces with line breaks, and apps set to paste, go through <see cref="InsertAsync"/>.
    /// Never steals focus: if the target isn't in front any more, it throws.
    /// </summary>
    public async Task TypeAsync(string text, InsertionTarget target, CancellationToken ct = default)
    {
        var s = _settings.Current;
        if (text.Contains('\n') || s.AppOverrides.TryGetValue(target.ProcessName, out var o) && o == InsertionMode.Clipboard)
        {
            await InsertAsync(text, target, ct);
            return;
        }
        await WaitForModifiersReleasedAsync(ct);
        if (!target.IsAlive || Native.GetForegroundWindow() != target.Hwnd)
            throw new UserFacingException("The app you were dictating into isn't in front any more.");
        await _typing.InsertAsync(text, target, ct);
    }

    /// <summary>Paste a short piece straight into the target (clipboard, restored after), for text that streams in as
    /// it is heard. Never steals focus: if the target isn't in front any more, it throws.</summary>
    public async Task PasteAsync(string text, InsertionTarget target, CancellationToken ct = default)
    {
        await WaitForModifiersReleasedAsync(ct);
        if (!target.IsAlive || Native.GetForegroundWindow() != target.Hwnd)
            throw new UserFacingException("The app you were dictating into isn't in front any more.");
        try { await _paste.InsertAsync(text, target, ct); }
        catch (Exception e) when (e is not (OperationCanceledException or UserFacingException))
        {
            throw new UserFacingException("Pasting into that app failed: " + e.Message, e);
        }
    }

    /// <summary>Erase the last <paramref name="text"/> typed (one Backspace per character) in the target.</summary>
    public async Task EraseAsync(string text, InsertionTarget target, CancellationToken ct = default)
    {
        var count = text.Count(c => !char.IsLowSurrogate(c)); // one Backspace removes a whole surrogate pair
        if (count == 0) return;
        await WaitForModifiersReleasedAsync(ct);
        if (!target.IsAlive || Native.GetForegroundWindow() != target.Hwnd)
            throw new UserFacingException("The app you were dictating into isn't in front any more.");
        const int batch = 4; // a few at a time, like typing: Chromium apps drop floods of keystrokes
        for (var i = 0; i < count; i += batch)
        {
            ct.ThrowIfCancellationRequested();
            var n = Math.Min(batch, count - i);
            var inputs = new Native.INPUT[n * 2];
            for (var k = 0; k < n; k++)
            {
                inputs[k * 2] = Native.Key(Native.VK_BACK, 0, 0);
                inputs[k * 2 + 1] = Native.Key(Native.VK_BACK, 0, Native.KEYEVENTF_KEYUP);
            }
            Native.Send(inputs);
            if (i + n < count) await Task.Delay(10, ct);
        }
    }

    /// <summary>Delete the current selection in the focused app (Backspace).</summary>
    public async Task DeleteSelectionAsync(CancellationToken ct = default)
    {
        await WaitForModifiersReleasedAsync(ct);
        Native.Send(new[] { Native.Key(Native.VK_BACK, 0, 0), Native.Key(Native.VK_BACK, 0, Native.KEYEVENTF_KEYUP) });
    }

    internal static async Task WaitForModifiersReleasedAsync(CancellationToken ct)
    {
        // The dictation hotkey's own modifiers may still be down; they would turn typed text into shortcuts.
        for (var i = 0; i < 40; i++)
        {
            var down = new[] { Native.VK_CONTROL, Native.VK_MENU, Native.VK_SHIFT, Native.VK_LWIN, Native.VK_RWIN }
                .Any(k => (Native.GetAsyncKeyState(k) & 0x8000) != 0);
            if (!down) return;
            await Task.Delay(25, ct);
        }
    }

    static async Task<bool> EnsureForegroundAsync(InsertionTarget target, CancellationToken ct)
    {
        if (Native.GetForegroundWindow() == target.Hwnd) return true;
        if (Native.IsIconic(target.Hwnd)) Native.ShowWindow(target.Hwnd, Native.SW_RESTORE);

        var fg = Native.GetForegroundWindow();
        var fgThread = Native.GetWindowThreadProcessId(fg, out _);
        var me = Native.GetCurrentThreadId();
        var attached = fgThread != 0 && fgThread != me && Native.AttachThreadInput(me, fgThread, true);
        try { Native.SetForegroundWindow(target.Hwnd); }
        finally { if (attached) Native.AttachThreadInput(me, fgThread, false); }

        for (var i = 0; i < 20; i++)
        {
            if (Native.GetForegroundWindow() == target.Hwnd) return true;
            await Task.Delay(25, ct);
        }
        return false;
    }
}
