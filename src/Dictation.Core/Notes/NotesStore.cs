using System.Collections.ObjectModel;
using System.Text;
using System.Text.Json;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Notes;

/// <summary>
/// Extended Notes sessions on disk: data\notes\&lt;yyyyMMdd-HHmmss&gt;\session.json and audio.wav, outside the program
/// folder so updates keep them. Newest first. Use from the UI thread (saving writes the file on a background thread).
/// </summary>
public sealed class NotesStore
{
    public static string Dir => Path.Combine(AppPaths.DataDir, "notes");
    static string DraftPath => Path.Combine(Dir, "draft.txt");
    public ObservableCollection<NoteSession> Sessions { get; } = new();
    /// <summary>Daily counts of the sessions, kept apart from the dictation statistics.</summary>
    public NotesUsage Usage { get; }
    readonly object _writeLock = new();
    readonly bool _disk;
    volatile string _draft = "";
    Timer? _draftTimer;

    public NotesStore(bool load = true)
    {
        _disk = load;
        Usage = new NotesUsage(load ? NotesUsage.DefaultPath : null);
        if (load) Load();
    }

    void Load()
    {
        try { if (File.Exists(DraftPath)) _draft = File.ReadAllText(DraftPath, Encoding.UTF8); }
        catch (Exception e) { Log.Warn("Extended notes: couldn't read the draft: " + e.Message); }
        if (!Directory.Exists(Dir)) return;
        var loaded = new List<NoteSession>();
        foreach (var folder in Directory.GetDirectories(Dir))
        {
            var s = JsonStore.Load<NoteSession>(Path.Combine(folder, "session.json"));
            if (s == null) continue;
            s.Folder = folder;
            if (!s.Finished)
            {
                // Oberton closed (or crashed) while it recorded: everything up to the last save is kept.
                s.Finished = true;
                Save(s);
                Log.Info("Extended notes: closed a session left open: " + s.Id);
            }
            loaded.Add(s);
        }
        foreach (var s in loaded.OrderByDescending(s => s.Started)) Sessions.Add(s);
    }

    /// <summary>A new session with its folder, first in the list.</summary>
    public NoteSession Create(NotesSource source)
    {
        var started = DateTime.Now;
        var folder = Path.Combine(Dir, started.ToString("yyyyMMdd-HHmmss"));
        for (var n = 2; Directory.Exists(folder); n++) folder = Path.Combine(Dir, started.ToString("yyyyMMdd-HHmmss") + "-" + n);
        Directory.CreateDirectory(folder);
        var s = new NoteSession
        {
            Started = started, Source = source, Folder = folder,
            Title = $"Session // {started:d MMM HH:mm}",
        };
        Sessions.Insert(0, s);
        Save(s);
        return s;
    }

    /// <summary>Save a session: serialized here (the UI thread owns it), written in the background.</summary>
    public void Save(NoteSession s)
    {
        if (s.Folder.Length == 0) return;
        string json;
        try { json = JsonSerializer.Serialize(s, JsonStore.Options); }
        catch (Exception e) { Log.Error("Extended notes: couldn't serialize a session", e); return; }
        var path = Path.Combine(s.Folder, "session.json");
        _ = Task.Run(() =>
        {
            lock (_writeLock)
            {
                try
                {
                    var tmp = path + ".tmp";
                    File.WriteAllText(tmp, json, Encoding.UTF8);
                    File.Move(tmp, path, true);
                }
                catch (Exception e) { Log.Warn("Extended notes: saving failed: " + e.Message); }
            }
        });
    }

    public void Delete(NoteSession s)
    {
        Sessions.Remove(s);
        NotesAudio.Forget(s.Id);
        try { if (s.Folder.Length > 0 && Directory.Exists(s.Folder)) Directory.Delete(s.Folder, true); }
        catch (Exception e) { Log.Warn("Extended notes: couldn't delete a session: " + e.Message); }
    }

    // ===== the dashboard's notes box between sessions =====

    /// <summary>What was typed in the dashboard's notes box while nothing recorded; the next session begins with it.</summary>
    public string Draft => _draft;

    /// <summary>The box changed: kept, and written to draft.txt a moment after the typing stops.</summary>
    public void SetDraft(string text)
    {
        if (text == _draft) return;
        _draft = text;
        if (!_disk) return;
        _draftTimer ??= new Timer(_ => WriteDraft());
        _draftTimer.Change(800, Timeout.Infinite);
    }

    /// <summary>A session starts: it takes the draft, which is cleared.</summary>
    public string TakeDraft()
    {
        var draft = _draft;
        if (draft.Length == 0) return "";
        _draft = "";
        if (_disk)
        {
            _draftTimer?.Change(Timeout.Infinite, Timeout.Infinite);
            _ = Task.Run(WriteDraft);
        }
        return draft;
    }

    /// <summary>Oberton is closing: write the draft now.</summary>
    public void FlushDraft()
    {
        if (!_disk || _draftTimer == null) return;
        _draftTimer.Change(Timeout.Infinite, Timeout.Infinite);
        WriteDraft();
    }

    void WriteDraft()
    {
        lock (_writeLock)
        {
            var text = _draft; // read under the lock, so an older text never lands after a newer one
            try
            {
                if (text.Length == 0) { if (File.Exists(DraftPath)) File.Delete(DraftPath); return; }
                Directory.CreateDirectory(Dir);
                var tmp = DraftPath + ".tmp";
                File.WriteAllText(tmp, text, Encoding.UTF8);
                File.Move(tmp, DraftPath, true);
            }
            catch (Exception e) { Log.Warn("Extended notes: saving the draft failed: " + e.Message); }
        }
    }
}

/// <summary>Extended Notes exports: one text, or all of them, as plain text or Markdown.</summary>
public static class NotesExport
{
    public enum Part { Transcript, Formatted, Summary, Everything }

    public static string Build(NoteSession s, Part part, bool markdown)
    {
        var sb = new StringBuilder();
        var length = TimeSpan.FromSeconds(s.Seconds);
        var when = $"{s.Started:dddd d MMMM yyyy, HH:mm} · {(int)length.TotalHours}:{length.Minutes:00}:{length.Seconds:00}";
        if (markdown) sb.Append("# ").AppendLine(s.Title).AppendLine().Append('_').Append(when).AppendLine("_").AppendLine();
        else sb.AppendLine(s.Title).AppendLine(when).AppendLine();

        void Section(string name, string text)
        {
            if (part == Part.Everything)
            {
                if (markdown) sb.Append("## ").AppendLine(name).AppendLine();
                else sb.AppendLine(name.ToUpperInvariant()).AppendLine();
            }
            sb.AppendLine(text.Trim()).AppendLine();
        }
        if (part is Part.Summary or Part.Everything) Section("Summary", s.Summary);
        // The moments the listener marked, one a line (a list in Markdown, or they would run into one line).
        if (part == Part.Everything && s.Markers.Count > 0)
            Section("Markers", string.Join(Environment.NewLine, s.Markers.Select(m => (markdown ? "- " : "") + NoteSession.MarkerLabel(m.Seconds))));
        if (part is Part.Formatted or Part.Everything) Section("Formatted", s.Formatted);
        if (part is Part.Transcript or Part.Everything) Section("Transcript", s.Transcript);
        return sb.ToString().TrimEnd() + Environment.NewLine;
    }
}
