using System.Windows.Controls;
using Dictation.Core.Infrastructure;
using Dictation.Core.Notes;
using Dictation.Core.Setup;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// The drop-down for Extended Notes' AI model, on Settings › Models and on the Extended Notes start card (one setting):
/// the best model on this PC (the default), the active model, each installed model, and cloud models that have a key
/// while "Keep everything offline" is off. A model the setting names that isn't available any more stays listed, marked,
/// so the setting isn't lost silently. Choosing saves at once; a session already recording uses it from its next step.
/// </summary>
static class NotesModelChoices
{
    sealed record Choice(string Label, string Value);

    /// <summary>Fill the box; returns the model "best" means now (null when no local model is installed) and the GPU's
    /// memory (null without an NVIDIA GPU), for the explanation beside it.</summary>
    public static async Task<(string? Best, long? Gpu)> FillAsync(ComboBox box)
    {
        var s = App.Services.Settings.Current;
        var installed = await App.Services.Llm.ListModelDetailsAsync();
        var gpu = await Task.Run(RuntimeInstaller.GpuMemoryBytes); // asks nvidia-smi the first time
        var best = NotesModels.PickBest(installed, gpu);
        var choices = new List<Choice>
        {
            new(best != null ? $"Best on this PC · {best.Name}" : "Best on this PC · no local model installed yet", NotesModels.Best),
            new($"Same as the active model · {s.Llm.DefaultModel}", NotesModels.Active),
        };
        choices.AddRange(installed.Where(m => NotesModels.IsChatModel(m) && !CloudModels.IsOllamaCloud(m.Name))
            .OrderByDescending(m => m.Billions).ThenBy(m => m.Name)
            .Select(m => new Choice($"{m.Name} · {m.Billions:0.#}B" + (NotesModels.Fits(m, gpu) ? "" : " · slow on this PC"), m.Name)));
        if (!s.Cloud.KeepOffline)
            choices.AddRange(installed.Where(m => CloudModels.IsOllamaCloud(m.Name)).OrderBy(m => m.Name)
                .Select(m => new Choice($"{m.Name} · cloud: the transcript goes to ollama.com", m.Name)));
        if (!s.Cloud.KeepOffline)
            choices.AddRange(CloudModels.Catalog(s.Cloud).Where(c => CloudModels.HasKey(s.Cloud, CloudModels.Split(c.Id).Provider))
                .Select(c => new Choice($"{c.Name} · cloud: the transcript goes to {c.Provider}", c.Id)));
        var current = s.NotesModel ?? "";
        if (choices.All(c => !string.Equals(c.Value, current, StringComparison.OrdinalIgnoreCase)))
            choices.Add(new Choice(current + " · not available", current));

        box.SelectionChanged -= OnChanged;
        box.DisplayMemberPath = nameof(Choice.Label);
        box.ItemsSource = choices;
        box.SelectedItem = choices.First(c => string.Equals(c.Value, current, StringComparison.OrdinalIgnoreCase));
        box.SelectionChanged += OnChanged;
        return (best?.Name, gpu);
    }

    /// <summary>What "best" means here, in a sentence.</summary>
    public static string Explain(string? best, long? gpu) =>
        "Extended Notes formats and sums up long sessions in the background, so it can use a bigger model than " +
        "dictation needs. Best on this PC is the largest installed model that " +
        (gpu is { } g ? $"fits in the GPU's memory ({NotesModels.Gb(g)} here)" : $"runs well without a GPU (up to {NotesModels.MaxBillionsWithoutGpu:0.#}B)") +
        (best != null ? $": {best}." : ".") +
        " A cloud model would send the whole transcript to that service.";

    static void OnChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ComboBox { SelectedItem: Choice c }) return;
        var s = App.Services.Settings.Current;
        if (string.Equals(s.NotesModel ?? "", c.Value, StringComparison.Ordinal)) return;
        s.NotesModel = c.Value;
        App.Services.Settings.Save();
        Log.Info("Extended notes: AI model set to " + (c.Value.Length == 0 ? "the best on this PC" : c.Value));
    }
}
