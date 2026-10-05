using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;
using Dictation.Core.Setup;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.App.Views;

/// <summary>What is active and loaded right now: the profile, the models, Read aloud, history, privacy. Refreshes itself.</summary>
public partial class DashboardPage : UserControl
{
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(3) };
    IReadOnlyList<string> _loadedAi = Array.Empty<string>();
    bool _refreshing;

    public DashboardPage()
    {
        InitializeComponent();
        _timer.Tick += async (_, _) => await RefreshAsync();
        Loaded += async (_, _) => { _timer.Start(); await RefreshAsync(); };
        Unloaded += (_, _) => _timer.Stop();
        Build();
    }

    async Task RefreshAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try { _loadedAi = await App.Services.Llm.LoadedModelsAsync(); }
        finally { _refreshing = false; }
        Build();
    }

    void Build()
    {
        var sv = App.Services;
        var s = sv.Settings.Current;
        var p = sv.Profiles.Active;
        var aiModel = string.IsNullOrWhiteSpace(p.Model) ? s.Llm.DefaultModel : p.Model!;
        var cloud = CloudModels.IsCloud(aiModel);
        var aiLoaded = _loadedAi.Any(n => n.StartsWith(aiModel, StringComparison.OrdinalIgnoreCase));
        var unload = s.UnloadAfterMinutes <= 0 ? "never" : s.UnloadAfterMinutes >= 60 ? $"{s.UnloadAfterMinutes / 60.0:0.#} h" : $"{s.UnloadAfterMinutes} min";
        Summary.Text = $"Press {s.Hotkey} to dictate with {p.Name}, and {s.SpeakHotkey} to hear selected text read aloud.";

        Cards.Children.Clear();

        Cards.Children.Add(Card("ACTIVE PROFILE", p.Name, p.Description, new[]
        {
            ("AI", p.AutoProcess ? (cloud ? "on · cloud" : "on · this PC") : "off (raw words)"),
            ("Model", p.AutoProcess ? aiModel + (string.IsNullOrWhiteSpace(p.Model) ? " (default)" : "") : "—"),
            ("Rewrites the whole dictation", p.AutoProcess && p.RewriteWhole ? "yes" : "no"),
            ("Preview before inserting", p.ShowPreview ? "yes" : "no"),
            ("Read aloud after inserting", p.ReadAloudAfterInsert ? "yes" : "no"),
            ("Type as you speak", s.TypeWhileSpeaking && !p.ShowPreview ? "on" : "off"),
            ("Switch profile", s.CycleProfileHotkey),
        }, ("Open profile", () => ((MainWindow)Window.GetWindow(this)!).ShowProfile(p))));

        Cards.Children.Add(Card("SPEECH RECOGNITION", s.Asr.Model, sv.Status.Speech.Replace("Speech: ", ""), new[]
        {
            ("State", sv.Speech.IsReady ? "loaded" : "not loaded · loads when you dictate"),
            ("Device", s.Asr.Device == "auto" ? "automatic (GPU if available)" : s.Asr.Device.ToUpperInvariant()),
            ("Language", string.IsNullOrEmpty(s.Asr.Language) ? "auto-detect" : s.Asr.Language),
            ("Dictation", sv.Controller.State == DictationState.Idle ? "idle" : sv.Controller.State.ToString().ToLowerInvariant()),
        }, ("Models", () => ((App)Application.Current).ShowPage("Models"))));

        Cards.Children.Add(Card("AI CLEANUP", aiModel, cloud ? "Cloud model" : sv.Status.Ai.Replace("AI: ", ""), new[]
        {
            ("Default model", s.Llm.DefaultModel),
            ("State", cloud ? (s.Cloud.KeepOffline ? "blocked by Keep everything offline" : "cloud · nothing to load")
                : aiLoaded ? "loaded" : "not loaded · loads when you dictate"),
            ("In memory", _loadedAi.Count == 0 ? "none" : string.Join(", ", _loadedAi)),
            ("Unload when unused for", unload),
        }, ("Models", () => ((App)Application.Current).ShowPage("Models"))));

        var voice = KokoroSpeech.Voices.FirstOrDefault(v => v.Id == s.TtsVoice)?.Name ?? s.TtsVoice;
        Cards.Children.Add(Card("READ ALOUD", RuntimeInstaller.ReadAloudInstalled ? voice : "Not installed yet",
            RuntimeInstaller.ReadAloudInstalled ? $"Select text anywhere and press {s.SpeakHotkey}." : "The voice downloads the first time you use it.", new[]
            {
                ("Voice engine", sv.Tts.IsRunning ? "loaded" : "not loaded · starts when you read"),
                ("Base speed", $"{s.TtsBaseSpeed:0.00}×"),
                ("Hotkey", s.SpeakHotkey),
                ("Player", s.ReaderExpanded ? "whole text" : "current sentence"),
            }, ("Text to speech", () => ((App)Application.Current).ShowPage("TextToSpeech"))));

        var last = sv.History.Entries.FirstOrDefault();
        Cards.Children.Add(Card("HISTORY", $"{sv.History.Entries.Count} of {s.HistoryLimit}",
            last == null ? "No dictations yet." : $"Last: {last.When} into {last.AppName}: “{last.Preview}”", new[]
            {
                ("Kept", s.KeepHistory ? (s.SaveHistoryAudio ? "text and recordings" : "text only") : "off"),
                ("Order", s.HistoryGrouping == Dictation.Core.Settings.HistoryGrouping.ByApp ? "by app" : "newest first"),
            }, ("History", () => ((App)Application.Current).ShowPage("History"))));

        Cards.Children.Add(Card("APP", $"{AppInfo.Name} {AppInfo.VersionText}",
            s.Cloud.KeepOffline ? "Everything stays on this PC." : "Cloud AI is allowed for profiles that use a cloud model.", new[]
            {
                ("Keep everything offline", s.Cloud.KeepOffline ? "on" : "off"),
                ("Dictate", s.Hotkey),
                ("Insert text by", s.Insertion.ToString().ToLowerInvariant()),
                ("Data folder", AppPaths.Root),
            }, ("Settings", () => ((App)Application.Current).ShowPage("General"))));
    }

    FrameworkElement Card(string label, string title, string subtitle, IEnumerable<(string Key, string Value)> rows,
        (string Text, Action Click) link)
    {
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = label, Style = (Style)FindResource("MonoLabel") });
        panel.Children.Add(new TextBlock
        {
            Text = title, FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var sub = new TextBlock { Text = subtitle, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 10) };
        sub.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        panel.Children.Add(sub);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var r = 0;
        foreach (var (key, value) in rows)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var k = new TextBlock { Text = key, FontSize = 12.5, Margin = new Thickness(0, 3, 14, 3) };
            k.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
            var v = new TextBlock { Text = value, FontSize = 12.5, Margin = new Thickness(0, 3, 0, 3), TextWrapping = TextWrapping.Wrap };
            Grid.SetRow(k, r);
            Grid.SetRow(v, r);
            Grid.SetColumn(v, 1);
            grid.Children.Add(k);
            grid.Children.Add(v);
            r++;
        }
        panel.Children.Add(grid);

        var button = new Button
        {
            Content = link.Text, Style = (Style)FindResource("QuietButton"), HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 12, 0, 0),
        };
        button.Click += (_, _) => link.Click();
        panel.Children.Add(button);

        return new Border
        {
            Style = (Style)FindResource("Card"), Padding = new Thickness(18, 14, 18, 14), Margin = new Thickness(8), Child = panel,
        };
    }
}
