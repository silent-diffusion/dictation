using System.Text;
using System.Text.Json;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Speech;

/// <summary>A word as the speech engine heard it, and when: seconds into the recording (audio.wav).</summary>
public sealed record WordTiming(string Text, double Start, double End);

/// <summary>
/// The timings of the words heard in a recording, as the speech engine sends them (<c>[[word, start, end], …]</c>) and as
/// they are kept beside it: words.json in a Notes session's or a History entry's folder,
/// <c>{"Version":1,"Words":[["Hello,",0.52,0.81],…]}</c>. Only the words that made it into the transcript are there (the
/// engine drops a filtered phrase's timings with it). Reading is forgiving: no file, a damaged one, or rows of another
/// shape just mean fewer (or no) words, and the text plays without highlighting.
/// </summary>
public static class WordTimings
{
    public const string FileName = "words.json";
    public const int Version = 1;

    /// <summary>Rows from JSON: <c>[word, start, end]</c> (or <c>{"Text","Start","End"}</c>); anything else is skipped.
    /// Ends before their start are raised to it; the words come back in order of their start.</summary>
    public static List<WordTiming> Parse(JsonElement rows)
    {
        var words = new List<WordTiming>();
        if (rows.ValueKind != JsonValueKind.Array) return words;
        foreach (var row in rows.EnumerateArray())
        {
            string? text = null;
            double start = double.NaN, end = double.NaN;
            if (row.ValueKind == JsonValueKind.Array && row.GetArrayLength() >= 3)
            {
                if (row[0].ValueKind == JsonValueKind.String) text = row[0].GetString();
                if (row[1].ValueKind == JsonValueKind.Number) start = row[1].GetDouble();
                if (row[2].ValueKind == JsonValueKind.Number) end = row[2].GetDouble();
            }
            else if (row.ValueKind == JsonValueKind.Object)
            {
                foreach (var p in row.EnumerateObject())
                {
                    if (p.NameEquals("Text") || p.NameEquals("text")) text = p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() : null;
                    else if ((p.NameEquals("Start") || p.NameEquals("start")) && p.Value.ValueKind == JsonValueKind.Number) start = p.Value.GetDouble();
                    else if ((p.NameEquals("End") || p.NameEquals("end")) && p.Value.ValueKind == JsonValueKind.Number) end = p.Value.GetDouble();
                }
            }
            text = text?.Trim();
            if (string.IsNullOrEmpty(text) || !double.IsFinite(start) || !double.IsFinite(end) || start < 0) continue;
            words.Add(new WordTiming(text, start, Math.Max(start, end)));
        }
        // Stable: words said at the same moment keep their order.
        return words.Select((w, i) => (w, i)).OrderBy(x => x.w.Start).ThenBy(x => x.i).Select(x => x.w).ToList();
    }

    /// <summary>The words kept in <paramref name="path"/>; none when there is no such file or it can't be read.</summary>
    public static List<WordTiming> Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return new();
            var bytes = File.ReadAllBytes(path);
            var bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0; // written by an editor
            using var doc = JsonDocument.Parse(bytes.AsMemory(bom), new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Array) return Parse(root);
            if (root.ValueKind != JsonValueKind.Object) return new();
            foreach (var p in root.EnumerateObject())
                if (p.NameEquals("Words") || p.NameEquals("words")) return Parse(p.Value);
            return new();
        }
        catch (Exception e)
        {
            Log.Warn($"Couldn't read the word timings in {path} (it plays without highlighting): {e.Message}");
            return new();
        }
    }

    /// <summary>The words as words.json holds them, compact (an hour of speech is about 9,000 words).</summary>
    public static string Serialize(IReadOnlyList<WordTiming> words)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteNumber("Version", Version);
            w.WriteStartArray("Words");
            foreach (var word in words)
            {
                w.WriteStartArray();
                w.WriteStringValue(word.Text);
                w.WriteNumberValue(Math.Round(word.Start, 2));
                w.WriteNumberValue(Math.Round(word.End, 2));
                w.WriteEndArray();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    /// <summary>Write words.json (through a temporary file, so a crash never leaves half of one); with no words, the
    /// file goes.</summary>
    public static void Save(string path, IReadOnlyList<WordTiming> words) => Write(path, words.Count == 0 ? null : Serialize(words));

    /// <summary>Write what <see cref="Serialize"/> made; null deletes the file.</summary>
    public static void Write(string path, string? json)
    {
        if (json == null)
        {
            if (File.Exists(path)) File.Delete(path);
            return;
        }
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(false));
        File.Move(tmp, path, true);
    }

    /// <summary>The words moved later by <paramref name="seconds"/> (from a part of a recording into the whole).</summary>
    public static List<WordTiming> Shifted(IEnumerable<WordTiming> words, double seconds) =>
        words.Select(w => seconds == 0 ? w : w with { Start = w.Start + seconds, End = w.End + seconds }).ToList();
}
