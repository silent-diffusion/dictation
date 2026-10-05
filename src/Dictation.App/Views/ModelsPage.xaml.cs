using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>
/// Every model Oberton can use, as a list: what each is for, whether it is downloaded, active and loaded, with a
/// Download or Use button. Speech recognition (Whisper), local AI cleanup (Ollama), cloud AI, and the Read aloud voice.
/// </summary>
public partial class ModelsPage : UserControl
{
    sealed record Option(string Id, string Name, string Description, string Size);

    static readonly Option[] SpeechModels =
    {
        new("large-v3-turbo", "Whisper large-v3 turbo", "The best balance: nearly the accuracy of large-v3, several times faster. Needs an NVIDIA GPU to keep up.", "1.6 GB"),
        new("large-v3", "Whisper large-v3", "The most accurate, and the slowest. GPU only.", "3 GB"),
        new("distil-large-v3", "Distil-Whisper large-v3", "English only. Fast and accurate on a GPU.", "1.5 GB"),
        new("medium.en", "Whisper medium (English)", "Good accuracy; slow on a CPU.", "1.5 GB"),
        new("small.en", "Whisper small (English)", "The pick for PCs without an NVIDIA GPU.", "470 MB"),
        new("base.en", "Whisper base (English)", "Tiny and quick; makes more mistakes.", "145 MB"),
    };

    static readonly Option[] LocalModels =
    {
        new("qwen2.5:3b", "Qwen 2.5 3B", "Fast, faithful cleanup. The default.", "1.9 GB"),
        new("llama3.2:3b", "Llama 3.2 3B", "Fast, natural phrasing.", "2.0 GB"),
        new("phi4-mini", "Phi-4 mini", "Good at following instructions.", "2.5 GB"),
        new("gemma3:4b", "Gemma 3 4B", "Strong writing for its size.", "3.3 GB"),
        new("qwen2.5:7b", "Qwen 2.5 7B", "Better rewriting (emails, summaries). Needs about 8 GB of GPU memory to be quick.", "4.7 GB"),
    };

    CancellationTokenSource? _download;

    public ModelsPage()
    {
        InitializeComponent();
        DataContext = App.Services.Settings.Current;
        AutoSave.Hook(this, () => App.Services.Settings.Save());
        Loaded += async (_, _) => await RebuildAsync();
        Unloaded += (_, _) => _download?.Cancel();
    }

    bool Busy => _download != null;

    async void Refresh_Click(object sender, RoutedEventArgs e) => await RebuildAsync();

    async Task RebuildAsync()
    {
        var s = App.Services.Settings.Current;
        var status = App.Services.Status;

        // Speech recognition
        SpeechList.Children.Clear();
        foreach (var m in SpeechModels)
        {
            var downloaded = RuntimeInstaller.WhisperModelPresent(m.Id);
            var active = string.Equals(s.Asr.Model, m.Id, StringComparison.OrdinalIgnoreCase);
            var badges = new List<(string, string)>();
            if (active) badges.Add(("ACTIVE", "active"));
            if (active && App.Services.Speech.IsReady) badges.Add(("LOADED", "ok"));
            badges.Add(downloaded ? ("DOWNLOADED", "plain") : ("NOT DOWNLOADED", "outline"));
            SpeechList.Children.Add(Row(m.Name, $"{m.Description} · {m.Size}", badges, row =>
            {
                if (!downloaded) return MakeButton("Download", () => DownloadSpeechAsync(m, row));
                if (active) return null;
                return MakeButton("Use this", async () =>
                {
                    s.Asr.Model = m.Id;
                    App.Services.Settings.Save();
                    await RebuildAsync();
                    await App.RestartSpeechAsync();
                    await RebuildAsync();
                }, primary: true);
            }));
        }

        // Local AI
        LocalList.Children.Clear();
        LocalList.Children.Add(new TextBlock { Text = "Checking…", Style = (Style)FindResource("Caption") });
        var installed = await App.Services.Llm.ListModelsAsync();
        var loaded = await App.Services.Llm.LoadedModelsAsync();
        LocalList.Children.Clear();
        static bool Same(string a, string b) =>
            string.Equals(a, b, StringComparison.OrdinalIgnoreCase) || string.Equals(a, b + ":latest", StringComparison.OrdinalIgnoreCase);
        var options = LocalModels.ToList();
        foreach (var name in installed.Where(n => !options.Any(o => Same(n, o.Id))))
            options.Add(new Option(name, name, "Installed on this PC.", ""));
        foreach (var m in options)
        {
            var downloaded = installed.Any(n => Same(n, m.Id));
            var active = Same(s.Llm.DefaultModel, m.Id) || Same(m.Id, s.Llm.DefaultModel);
            var badges = new List<(string, string)>();
            if (active) badges.Add(("ACTIVE", "active"));
            if (loaded.Any(n => Same(n, m.Id))) badges.Add(("LOADED", "ok"));
            badges.Add(downloaded ? ("DOWNLOADED", "plain") : ("NOT DOWNLOADED", "outline"));
            var desc = m.Size.Length > 0 ? $"{m.Description} · {m.Size}" : m.Description;
            LocalList.Children.Add(Row(m.Name, desc, badges, row =>
            {
                if (!downloaded) return MakeButton("Download", () => DownloadLocalAsync(m, row));
                if (active) return null;
                return MakeButton("Use this", () => UseAiAsync(m.Id), primary: true);
            }));
        }
        if (installed.Count == 0)
            LocalList.Children.Insert(0, new TextBlock
            {
                Text = "The local AI runtime isn't answering, so downloaded models can't be listed. " + status.Ai,
                Style = (Style)FindResource("Caption"),
            });

        // Cloud AI
        CloudList.Children.Clear();
        var cloud = s.Cloud;
        CloudNote.Text = cloud.KeepOffline
            ? "\"Keep everything offline\" is on, so cloud models are blocked. Change that and add keys under Settings › Cloud AI."
            : "Text you dictate with a profile set to one of these is sent to that service. Keys are set under Settings › Cloud AI.";
        foreach (var m in CloudModels.Catalog(cloud))
        {
            var (provider, _) = CloudModels.Split(m.Id);
            var hasKey = CloudModels.HasKey(cloud, provider);
            var active = string.Equals(s.Llm.DefaultModel, m.Id, StringComparison.OrdinalIgnoreCase);
            var badges = new List<(string, string)> { ("CLOUD", "cloud") };
            if (active) badges.Add(("ACTIVE", "active"));
            badges.Add(hasKey ? ("KEY SET", "plain") : ("NO KEY", "outline"));
            if (cloud.KeepOffline) badges.Add(("BLOCKED · OFFLINE", "outline"));
            CloudList.Children.Add(Row(m.Name, $"{m.Provider} · {m.Description}", badges, _ =>
            {
                if (!hasKey) return MakeButton("Add key", () => { ((App)Application.Current).ShowPage("Cloud"); return Task.CompletedTask; });
                if (active) return null;
                return MakeButton("Use this", () => UseAiAsync(m.Id), primary: true);
            }));
        }

        // Read aloud: Kokoro, Piper (voice by voice) and the Windows voices
        VoiceList.Children.Clear();
        var activeModel = VoiceCatalog.ModelOf(s.TtsVoice);
        var voice = RuntimeInstaller.ReadAloudInstalled;
        var voiceBadges = new List<(string, string)>();
        if (voice && activeModel == VoiceCatalog.Kokoro) voiceBadges.Add(("ACTIVE", "active"));
        if (App.Services.Tts.IsRunning) voiceBadges.Add(("LOADED", "ok"));
        voiceBadges.Add(voice ? ("DOWNLOADED", "plain") : ("NOT DOWNLOADED", "outline"));
        VoiceList.Children.Add(Row("Kokoro v1.0", $"{VoiceCatalog.Model(VoiceCatalog.Kokoro).Description} {VoiceCatalog.KokoroVoices.Count} voices.",
            voiceBadges, row => voice ? null : MakeButton("Download", () => DownloadVoiceAsync(row))));

        foreach (var pv in VoiceCatalog.PiperVoices)
        {
            var have = RuntimeInstaller.PiperVoiceInstalled(pv.Name);
            var active = s.TtsVoice == pv.Id;
            var badges = new List<(string, string)>();
            if (active) badges.Add(("ACTIVE", "active"));
            badges.Add(have ? ("DOWNLOADED", "plain") : ("NOT DOWNLOADED", "outline"));
            VoiceList.Children.Add(Row($"Piper · {pv.Label}", $"{pv.Kind} · light and fast · {pv.Mb} MB", badges, row =>
                !have ? MakeButton("Download", () => DownloadPiperAsync(pv, row))
                : active ? null : MakeButton("Use this", () => UseVoiceAsync(pv.Id), primary: true)));
        }

        var windowsVoices = WindowsSpeech.InstalledVoices();
        VoiceList.Children.Add(Row("Windows voices", windowsVoices.Count == 0
                ? "No Windows voices found. Add some under Windows Settings › Time & language › Speech."
                : $"{windowsVoices.Count} installed with Windows ({string.Join(", ", windowsVoices.Select(v => v.Name.Split(" (")[0]))}); instant, no download",
            new List<(string, string)>(activeModel == VoiceCatalog.Windows ? new[] { ("ACTIVE", "active") } : Array.Empty<(string, string)>())
                { windowsVoices.Count > 0 ? ("INSTALLED", "plain") : ("NONE", "outline") }, _ => null));
    }

    async Task UseVoiceAsync(string id)
    {
        App.Services.Settings.Current.TtsVoice = id;
        App.Services.Settings.Save();
        await RebuildAsync();
    }

    async Task DownloadPiperAsync(PiperVoice v, RowParts row) => await RunDownloadAsync(row, async (installer, ct) =>
        await installer.InstallPiperVoiceAsync(v, new Progress<SetupProgress>(p => Progress(row, p.Fraction)), ct));

    async Task UseAiAsync(string id)
    {
        App.Services.Settings.Current.Llm.DefaultModel = id;
        App.Services.Settings.Save();
        await RebuildAsync();
        await App.Services.Llm.WarmUpAsync(null);
        await RebuildAsync();
    }

    // ----- downloads -----

    async Task DownloadSpeechAsync(Option m, RowParts row) => await RunDownloadAsync(row, async (installer, ct) =>
        await installer.DownloadWhisperAsync(m.Id, (f, _) => Progress(row, f), ct));

    async Task DownloadLocalAsync(Option m, RowParts row) => await RunDownloadAsync(row, async (installer, ct) =>
        await installer.DownloadAiModelAsync(m.Id, f => Progress(row, f), ct));

    async Task DownloadVoiceAsync(RowParts row) => await RunDownloadAsync(row, async (installer, ct) =>
        await installer.InstallReadAloudAsync(new Progress<SetupProgress>(p => Progress(row, p.Fraction)), ct));

    async Task RunDownloadAsync(RowParts row, Func<RuntimeInstaller, CancellationToken, Task> work)
    {
        if (Busy) return;
        _download = new CancellationTokenSource();
        row.Bar.Visibility = Visibility.Visible;
        row.Bar.IsIndeterminate = true;
        row.Actions.Children.Clear();
        row.Actions.Children.Add(MakeButton("Cancel", () => { _download?.Cancel(); return Task.CompletedTask; }));
        try
        {
            await work(new RuntimeInstaller(App.Services.Settings, App.Services.OllamaHost), _download.Token);
        }
        catch (OperationCanceledException) { }
        catch (UserFacingException ex) { MessageBox.Show(ex.Message, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning); }
        catch (Exception ex)
        {
            Log.Error("Model download failed", ex);
            MessageBox.Show("The download failed. See the log for details.", AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { _download = null; }
        await RebuildAsync();
    }

    void Progress(RowParts row, double? fraction) => Dispatcher.BeginInvoke(() =>
    {
        row.Bar.IsIndeterminate = fraction == null;
        if (fraction is { } f) row.Bar.Value = f;
    });

    // ----- building the rows -----

    sealed record RowParts(ProgressBar Bar, StackPanel Actions);

    /// <param name="badges">Text and kind: active, ok, plain, outline, cloud.</param>
    /// <param name="action">The row's button, or null.</param>
    UIElement Row(string name, string description, IEnumerable<(string Text, string Kind)> badges, Func<RowParts, Button?> action)
    {
        var title = new WrapPanel();
        title.Children.Add(new TextBlock { Text = name, FontSize = 14, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 10, 2) });
        foreach (var (text, kind) in badges) title.Children.Add(Badge(text, kind));

        var bar = new ProgressBar { Height = 4, Minimum = 0, Maximum = 1, Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed };
        var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        info.Children.Add(title);
        var desc = new TextBlock { Text = description, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) };
        desc.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        info.Children.Add(desc);
        info.Children.Add(bar);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
        var parts = new RowParts(bar, actions);
        if (action(parts) is { } button)
        {
            button.IsEnabled = !Busy;
            actions.Children.Add(button);
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(info);
        Grid.SetColumn(actions, 1);
        grid.Children.Add(actions);

        return new Border
        {
            Style = (Style)FindResource("Card"),
            Padding = new Thickness(16, 12, 14, 12),
            Margin = new Thickness(0, 0, 0, 8),
            Child = grid,
        };
    }

    Button MakeButton(string text, Func<Task> click, bool primary = false)
    {
        var b = new Button { Content = text, Style = (Style)FindResource(primary ? "PrimaryButton" : "QuietButton") };
        b.Click += async (_, _) => await click();
        return b;
    }

    static Border Badge(string text, string kind)
    {
        var label = new TextBlock { Text = text, FontSize = 10.5, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        var badge = new Border
        {
            CornerRadius = new CornerRadius(9), Padding = new Thickness(7, 1, 7, 1), Margin = new Thickness(0, 0, 6, 2),
            VerticalAlignment = VerticalAlignment.Center, BorderThickness = new Thickness(1), Child = label,
        };
        switch (kind)
        {
            case "active":
                badge.SetResourceReference(Border.BackgroundProperty, "Ob.Strong");
                badge.SetResourceReference(Border.BorderBrushProperty, "Ob.Strong");
                label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.OnStrong");
                break;
            case "ok":
                badge.SetResourceReference(Border.BorderBrushProperty, "Ob.Ok");
                label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Ok");
                break;
            case "cloud":
                badge.SetResourceReference(Border.BorderBrushProperty, "Ob.Record");
                label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Record");
                break;
            case "plain":
                badge.SetResourceReference(Border.BackgroundProperty, "Ob.Subtle");
                badge.SetResourceReference(Border.BorderBrushProperty, "Ob.Subtle");
                label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
                break;
            default:
                badge.SetResourceReference(Border.BorderBrushProperty, "Ob.Border");
                label.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
                break;
        }
        return badge;
    }
}
