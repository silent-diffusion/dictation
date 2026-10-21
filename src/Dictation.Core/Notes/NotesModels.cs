using Dictation.Core.Infrastructure;
using Dictation.Core.Text;

namespace Dictation.Core.Notes;

/// <summary>
/// Which AI model formats and sums up Extended Notes (Settings › Models, and the Extended Notes start card). The
/// default is the best one on this PC: the largest installed model that fits in the GPU's memory, since notes run in the
/// background and gain more from a stronger model than they lose to its speed. A model can also be picked by name, or
/// the active model (the one dictation uses by default) followed. A mixture-of-experts model (Qwen3 30B-A3B) also fits
/// when it fits in the PC's memory: only a few billion of its parameters work on each word, so the processor keeps up.
/// </summary>
public static class NotesModels
{
    /// <summary>The setting's value for "the best model on this PC" (the default).</summary>
    public const string Best = "";
    /// <summary>The setting's value for "the active model" (Settings › Models).</summary>
    public const string Active = "active";
    /// <summary>Without a GPU, larger models are too slow to keep up with a lecture.</summary>
    public const double MaxBillionsWithoutGpu = 4.5;

    /// <summary>A model that writes text (not an embedding model, which only turns text into numbers).</summary>
    public static bool IsChatModel(LocalModel m) =>
        !m.Name.Contains("embed", StringComparison.OrdinalIgnoreCase) && !m.Family.Contains("bert", StringComparison.OrdinalIgnoreCase);

    /// <summary>Whether a model fits: in the GPU's memory when there is one, otherwise small enough for the processor;
    /// or a mixture of experts that runs from the PC's memory (<paramref name="ramBytes"/>, null when not known).</summary>
    public static bool Fits(LocalModel m, long? gpuBytes, long? ramBytes = null) =>
        (gpuBytes is { } g ? m.Bytes <= g : m.Billions <= MaxBillionsWithoutGpu) || m.RunsFromMemory(gpuBytes, ramBytes);

    /// <summary>The best installed model: the most parameters among those that fit, then the larger file (a finer
    /// quantization); null when none is installed. Never one of Ollama's cloud models: they show in its list like
    /// installed ones (huge, with a tiny file), but they run on ollama.com, so the transcript would leave this PC.</summary>
    public static LocalModel? PickBest(IEnumerable<LocalModel> installed, long? gpuBytes, long? ramBytes = null)
    {
        var chat = installed.Where(m => IsChatModel(m) && !CloudModels.IsOllamaCloud(m.Name)).ToList();
        return chat.Where(m => Fits(m, gpuBytes, ramBytes))
                   .OrderByDescending(m => m.Billions).ThenByDescending(m => m.Bytes).ThenBy(m => m.Name, StringComparer.Ordinal)
                   .FirstOrDefault()
               // Nothing fits: the smallest there is, rather than nothing.
               ?? chat.OrderBy(m => m.Bytes).FirstOrDefault();
    }

    static bool Same(string a, string b) =>
        string.Equals(a, b, StringComparison.OrdinalIgnoreCase) ||
        string.Equals(a, b + ":latest", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(a + ":latest", b, StringComparison.OrdinalIgnoreCase);

    /// <summary>The model the setting means right now, and why (for the log). A model picked by name that is no longer
    /// installed falls back to the best one; if the models can't be listed, the active model is used.</summary>
    public static async Task<(string Model, string Why)> ResolveAsync(string? setting, string activeModel,
        Func<Task<IReadOnlyList<LocalModel>>> list, long? gpuBytes, long? ramBytes = null)
    {
        setting = (setting ?? "").Trim();
        if (string.Equals(setting, Active, StringComparison.OrdinalIgnoreCase)) return (activeModel, "the active model");
        if (setting.Length > 0 && CloudModels.IsCloud(setting)) return (setting, "chosen, cloud");
        IReadOnlyList<LocalModel> installed;
        try { installed = await list(); }
        catch (Exception e)
        {
            Log.Warn("Extended notes: couldn't list the AI models: " + e.Message);
            return (activeModel, "the active model; the models couldn't be listed");
        }
        if (setting.Length > 0)
        {
            if (installed.FirstOrDefault(m => Same(m.Name, setting)) is { } chosen) return (chosen.Name, "chosen");
            Log.Warn($"Extended notes: the chosen AI model {setting} isn't installed; using the best one instead");
        }
        if (PickBest(installed, gpuBytes, ramBytes) is { } best)
            return (best.Name, best.RunsFromMemory(gpuBytes, ramBytes) ? $"best on this PC: a mixture of experts that runs from {Gb(ramBytes!.Value)} of memory"
                : gpuBytes is { } g ? $"best on this PC: the largest that fits in {Gb(g)} of GPU memory" : "best on this PC without a GPU");
        return (activeModel, "the active model; no local model is installed");
    }

    /// <summary>Bytes as "6 GB" (one decimal below 10).</summary>
    public static string Gb(long bytes)
    {
        var gb = bytes / (1024.0 * 1024 * 1024);
        return gb < 10 ? $"{gb:0.#} GB" : $"{gb:0} GB";
    }
}
