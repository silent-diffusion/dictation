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
    public ObservableCollection<NoteSession> Sessions { get; } = new();
    readonly object _writeLock = new();

    public NotesStore(bool load = true)
    {
        if (load) Load();
    }

    void Load()
    {
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
        try { if (s.Folder.Length > 0 && Directory.Exists(s.Folder)) Directory.Delete(s.Folder, true); }
        catch (Exception e) { Log.Warn("Extended notes: couldn't delete a session: " + e.Message); }
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
        if (part is Part.Formatted or Part.Everything) Section("Formatted", s.Formatted);
        if (part is Part.Transcript or Part.Everything) Section("Transcript", s.Transcript);
        return sb.ToString().TrimEnd() + Environment.NewLine;
    }
}
