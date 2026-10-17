using System.Collections.ObjectModel;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Xml;
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
        NotesAudio.Sweep(Sessions.Select(x => x.Id));
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

/// <summary>Extended Notes exports: one text, or all of them, as plain text, Markdown or a Word document.</summary>
public static class NotesExport
{
    public enum Part { Transcript, Formatted, Summary, Everything }

    public static string Build(NoteSession s, Part part, bool markdown)
    {
        var sb = new StringBuilder();
        var when = When(s);
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
        Sections(s, part, Section, markdown ? "- " : "");
        return sb.ToString().TrimEnd() + Environment.NewLine;
    }

    /// <summary>The line under the title: the date and the length recorded.</summary>
    static string When(NoteSession s)
    {
        var length = TimeSpan.FromSeconds(s.Seconds);
        return $"{s.Started:dddd d MMMM yyyy, HH:mm} · {(int)length.TotalHours}:{length.Minutes:00}:{length.Seconds:00}";
    }

    /// <summary>The parts an export includes, in the order they are written: Summary, Formatted, Transcript.</summary>
    /// <param name="markerBullet">Put before each marker's time (a list in Markdown, or they would run into one line).</param>
    static void Sections(NoteSession s, Part part, Action<string, string> section, string markerBullet)
    {
        if (part is Part.Summary or Part.Everything) section("Summary", s.Summary);
        // The moments the listener marked, one a line.
        if (part == Part.Everything && s.Markers.Count > 0)
            section("Markers", string.Join(Environment.NewLine, s.Markers.Select(m => markerBullet + NoteSession.MarkerLabel(m.Seconds))));
        if (part is Part.Formatted or Part.Everything) section("Formatted", s.Formatted);
        if (part is Part.Transcript or Part.Everything) section("Transcript", s.Transcript);
    }

    // ===== Word (.docx): a minimal WordprocessingML package, no library =====

    const string WordNs = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

    const string ContentTypesXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """;

    const string PackageRelsXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """;

    const string DocumentRelsXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """;

    // Title, Heading 1 and Normal as Word's own built-in styles (by name and outline level), so the document shows
    // real headings and the Navigation pane lists the parts.
    const string StylesXml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:docDefaults>
            <w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>
            <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault>
          </w:docDefaults>
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
          <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style>
          <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr></w:style>
        </w:styles>
        """;

    /// <summary>
    /// The same export as a Word document: the title, the date line, then each part under a heading (Everything) with
    /// the text's blank lines as paragraph breaks and its other line breaks kept. A plain package written by hand, so
    /// it needs no library; it opens in Word without a repair.
    /// </summary>
    public static byte[] BuildDocx(NoteSession s, Part part)
    {
        var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            Fixed(zip, "[Content_Types].xml", ContentTypesXml);
            Fixed(zip, "_rels/.rels", PackageRelsXml);
            Fixed(zip, "word/_rels/document.xml.rels", DocumentRelsXml);
            Fixed(zip, "word/styles.xml", StylesXml);
            using var stream = zip.CreateEntry("word/document.xml", CompressionLevel.Optimal).Open();
            using var xml = XmlWriter.Create(stream, new XmlWriterSettings { Encoding = new UTF8Encoding(false), CloseOutput = false });
            WriteDocument(xml, s, part);
        }
        return ms.ToArray();
    }

    static void Fixed(ZipArchive zip, string name, string xml)
    {
        using var stream = zip.CreateEntry(name, CompressionLevel.Optimal).Open();
        var bytes = Encoding.UTF8.GetBytes(xml);
        stream.Write(bytes, 0, bytes.Length);
    }

    static void WriteDocument(XmlWriter x, NoteSession s, Part part)
    {
        x.WriteStartDocument(true);
        x.WriteStartElement("w", "document", WordNs);
        x.WriteStartElement("w", "body", WordNs);
        Paragraph(x, "Title", XmlSafe(s.Title));
        Paragraph(x, null, XmlSafe(When(s)));
        Sections(s, part, (name, text) =>
        {
            if (part == Part.Everything) Paragraph(x, "Heading1", name);
            foreach (var p in Paragraphs(XmlSafe(text))) Paragraph(x, null, p);
        }, markerBullet: "");
        x.WriteEndElement(); // body
        x.WriteEndElement(); // document
        x.WriteEndDocument();
    }

    /// <summary>One paragraph in the given style (null: Normal); its line breaks become &lt;w:br/&gt;. The writer escapes
    /// &amp;, &lt;, &gt; and quotes itself.</summary>
    static void Paragraph(XmlWriter x, string? style, string text)
    {
        x.WriteStartElement("w", "p", WordNs);
        if (style != null)
        {
            x.WriteStartElement("w", "pPr", WordNs);
            x.WriteStartElement("w", "pStyle", WordNs);
            x.WriteAttributeString("w", "val", WordNs, style);
            x.WriteEndElement();
            x.WriteEndElement();
        }
        x.WriteStartElement("w", "r", WordNs);
        var lines = text.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            if (i > 0) { x.WriteStartElement("w", "br", WordNs); x.WriteEndElement(); }
            x.WriteStartElement("w", "t", WordNs);
            x.WriteAttributeString("xml", "space", "http://www.w3.org/XML/1998/namespace", "preserve");
            x.WriteString(lines[i]);
            x.WriteEndElement();
        }
        x.WriteEndElement(); // r
        x.WriteEndElement(); // p
    }

    /// <summary>The text's paragraphs: runs of lines between blank lines; none for an empty text.</summary>
    static IEnumerable<string> Paragraphs(string text)
    {
        var lines = new List<string>();
        foreach (var line in text.Split('\n'))
        {
            if (line.Trim().Length > 0) { lines.Add(line.TrimEnd()); continue; }
            if (lines.Count > 0) { yield return string.Join("\n", lines); lines.Clear(); }
        }
        if (lines.Count > 0) yield return string.Join("\n", lines);
    }

    /// <summary>The text with its line breaks as \n and without what XML 1.0 can't carry: control characters other
    /// than tab and newline, and half an emoji.</summary>
    internal static string XmlSafe(string text)
    {
        text = text.Replace("\r\n", "\n").Replace('\r', '\n');
        var sb = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) { sb.Append(c).Append(text[++i]); continue; }
            if (char.IsSurrogate(c) || c == '\uFFFE' || c == '\uFFFF') continue;
            if (c < ' ' && c != '\t' && c != '\n') continue;
            sb.Append(c);
        }
        return sb.ToString();
    }
}
