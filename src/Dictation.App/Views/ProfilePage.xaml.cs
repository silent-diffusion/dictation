using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Setup;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.App.Views;

public partial class ProfilePage : UserControl
{
    readonly Profile _profile;

    public ProfilePage(Profile profile)
    {
        _profile = profile;
        InitializeComponent();
        DataContext = profile;
        AutoSave.Hook(this, () => App.Services.Profiles.Save());
        ShowAiColumn();
        profile.PropertyChanged += OnProfileChanged;
        Unloaded += (_, _) => profile.PropertyChanged -= OnProfileChanged;
        FillVoices();
        FillSpeechModels();
        Loaded += async (_, _) => FillModels(await App.Services.Llm.ListModelsAsync());
    }

    /// <summary>A choice in one of the page's drop-downs; Value "" = use the app-wide setting.</summary>
    sealed record Choice(string Label, string Value);
    bool _filling;

    /// <summary>Only what can actually run: the models downloaded to this PC, and cloud models that have a key while
    /// "Keep everything offline" is off. A model the profile names that isn't available any more stays listed (marked)
    /// so the setting isn't lost silently.</summary>
    void FillModels(IReadOnlyList<string> downloaded)
    {
        var s = App.Services.Settings.Current;
        var choices = new List<Choice> { new($"Active model ({s.Llm.DefaultModel})", "") };
        choices.AddRange(downloaded.Select(m => new Choice(m, m)));
        if (!s.Cloud.KeepOffline)
            choices.AddRange(CloudModels.Catalog(s.Cloud).Where(c => CloudModels.HasKey(s.Cloud, CloudModels.Split(c.Id).Provider))
                .Select(c => new Choice($"{c.Name} · cloud", c.Id)));
        var current = _profile.Model ?? "";
        if (current.Length > 0 && choices.All(c => !string.Equals(c.Value, current, StringComparison.OrdinalIgnoreCase)))
            choices.Add(new Choice(current + " (not available)", current));
        Select(ModelBox, choices, current);
    }

    /// <summary>Read aloud model, then voice. Only what can be used right now (downloaded); "Read aloud's" follows the
    /// Read aloud page. A voice the profile names that isn't downloaded any more stays listed (marked).</summary>
    void FillVoices()
    {
        var s = App.Services.Settings.Current;
        var available = VoiceCatalog.Available();
        var models = new List<Choice>
        {
            new($"Same as Read aloud ({VoiceCatalog.Model(VoiceCatalog.ModelOf(s.TtsVoice)).Name} · {VoiceCatalog.ShortName(s.TtsVoice)})", ""),
        };
        models.AddRange(VoiceCatalog.Models.Where(m => available.Any(v => v.Model == m.Id) || VoiceCatalog.ModelOf(_profile.Voice) == m.Id && !string.IsNullOrEmpty(_profile.Voice))
            .Select(m => new Choice(m.Name, m.Id)));
        Select(TtsModelBox, models, string.IsNullOrEmpty(_profile.Voice) ? "" : VoiceCatalog.ModelOf(_profile.Voice));
        FillVoicesOf((TtsModelBox.SelectedItem as Choice)?.Value ?? "");
    }

    void FillVoicesOf(string model)
    {
        if (model.Length == 0)
        {
            VoiceBox.IsEnabled = false;
            Select(VoiceBox, new List<Choice> { new(VoiceCatalog.ShortName(App.Services.Settings.Current.TtsVoice), "") }, "");
            return;
        }
        VoiceBox.IsEnabled = true;
        var voices = VoiceCatalog.Available().Where(v => v.Model == model).Select(v => new Choice(v.Name, v.Id)).ToList();
        var current = _profile.Voice ?? "";
        if (VoiceCatalog.ModelOf(current) == model && current.Length > 0 && voices.All(v => v.Value != current))
            voices.Add(new Choice(VoiceCatalog.ShortName(current) + " (not downloaded)", current));
        if (voices.Count == 0) { Select(VoiceBox, new List<Choice> { new("No voices downloaded", "") }, ""); return; }
        Select(VoiceBox, voices, current);
        if (VoiceBox.SelectedItem is Choice c && c.Value != current) _profile.Voice = c.Value; // a new model: its first voice
    }

    void TtsModelBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling || TtsModelBox.SelectedItem is not Choice c) return;
        if (c.Value.Length == 0) _profile.Voice = null;
        FillVoicesOf(c.Value);
    }

    void Select(ComboBox box, List<Choice> choices, string value)
    {
        _filling = true;
        box.ItemsSource = choices;
        box.SelectedItem = choices.FirstOrDefault(c => string.Equals(c.Value, value, StringComparison.OrdinalIgnoreCase)) ?? choices[0];
        _filling = false;
    }

    /// <summary>Downloaded Whisper models only, plus "the one in Settings". A model the profile names that isn't
    /// downloaded any more stays listed (marked).</summary>
    void FillSpeechModels()
    {
        var asr = App.Services.Settings.Current.Asr;
        var choices = new List<Choice> { new($"Same as Settings › Models ({SpeechModels.NameOf(asr.Model)})", "") };
        choices.AddRange(SpeechModels.All.Where(m => RuntimeInstaller.WhisperModelPresent(m.Id)).Select(m => new Choice(m.Name, m.Id)));
        var current = _profile.SpeechModel ?? "";
        if (current.Length > 0 && choices.All(c => !string.Equals(c.Value, current, StringComparison.OrdinalIgnoreCase)))
            choices.Add(new Choice(SpeechModels.NameOf(current) + " (not downloaded)", current));
        Select(SpeechModelBox, choices, current);
    }

    void SpeechModelBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling || SpeechModelBox.SelectedItem is not Choice c) return;
        _profile.SpeechModel = c.Value.Length == 0 ? null : c.Value;
    }

    void ModelBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling || ModelBox.SelectedItem is not Choice c) return;
        _profile.Model = c.Value.Length == 0 ? null : c.Value;
    }

    void VoiceBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling || VoiceBox.SelectedItem is not Choice c) return;
        _profile.Voice = c.Value.Length == 0 ? null : c.Value;
    }

    void OnProfileChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Profile.AutoProcess)) ShowAiColumn();
    }

    /// <summary>The AI Edit box is always there; without AI it says so.</summary>
    void ShowAiColumn()
    {
        TestDiff.Inlines.Clear();
        TestDiff.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        TestDiff.Text = _profile.AutoProcess ? "Run the profile to see what it changes."
            : "No AI edit: this profile doesn't use AI.";
        TestOutput.Text = "";
        TestMeta.Text = "";
    }

    void SetActive_Click(object sender, RoutedEventArgs e) => App.Services.Profiles.SetActive(_profile);
    void MakeDefault_Click(object sender, RoutedEventArgs e) => App.Services.Profiles.SetDefault(_profile);

    void More_Click(object sender, RoutedEventArgs e)
    {
        var makeDefault = new MenuItem { Header = _profile.IsDefault ? "Default profile" : "Make default", IsEnabled = !_profile.IsDefault };
        makeDefault.Click += MakeDefault_Click;
        var delete = new MenuItem { Header = "Delete profile…" };
        delete.Click += Delete_Click;
        var menu = new ContextMenu { PlacementTarget = (UIElement)sender, Placement = PlacementMode.Bottom };
        menu.Items.Add(makeDefault);
        menu.Items.Add(delete);
        menu.IsOpen = true;
    }

    void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (App.Services.Profiles.Profiles.Count <= 1)
        {
            MessageBox.Show("You need at least one profile.", AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (MessageBox.Show($"Delete the profile \"{_profile.Name}\"?", AppInfo.Name, MessageBoxButton.YesNo,
                MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        App.Services.Profiles.Delete(_profile);
    }

    async void Run_Click(object sender, RoutedEventArgs e)
    {
        RunButton.IsEnabled = false;
        TestMeta.Text = "";
        TestDiff.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        TestDiff.Text = _profile.AutoProcess ? "Processing…" : "No AI edit: this profile doesn't use AI.";
        TestOutput.Text = "";
        var input = TestInput.Text;
        try
        {
            var result = _profile.AutoProcess
                ? await App.Services.Llm.ProcessAsync(input, _profile)
                : new ProcessResult(FragmentStitcher.Tidy(input), false, null); // no AI: only spacing and the first capital
            // AI Edit: what the AI changed, struck through and added. Inserted: the clean result.
            if (_profile.AutoProcess)
            {
                TestDiff.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
                DiffText.Render(TestDiff, WordDiff.Compute(input, result.Text),
                    (Brush)FindResource("Ob.DiffRemoved"), (Brush)FindResource("Ob.DiffAdded"));
            }
            else ShowAiColumn();
            TestMeta.Text = !result.SafetyNet ? LengthChange(input, result.Text)
                : result.Modified ? "safety net: some parts kept as spoken" : "safety net: original kept";
            if (result.Warning != null && !result.SafetyNet) TestMeta.Text = result.Warning;
            if (!_profile.AutoProcess) TestMeta.Text = "";
            // Try it follows the profile's own switches: the preview decides what goes in, and Read aloud reads it.
            var final = result.Text;
            if (_profile.ShowPreview)
            {
                TestOutput.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
                TestOutput.Text = "Waiting for your choice in the preview…";
                var chosen = await ((App)Application.Current).PreviewTrialAsync(_profile.Name, input, result.Text, _profile.AutoProcess);
                if (chosen == null)
                {
                    TestOutput.Text = "Discarded in the preview: nothing would be inserted.";
                    return;
                }
                final = chosen;
            }
            TestOutput.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            TestOutput.Text = final;
            if (_profile.ReadAloudAfterInsert && final.Trim().Length > 0) ((App)Application.Current).ReadAloud(final.Trim(), App.VoiceFor(_profile));
        }
        catch (UserFacingException ex) { ShowProblem(ex.Message); }
        catch (Exception ex) { Log.Error("Profile test failed", ex); ShowProblem("Something went wrong. See the log."); }
        finally { RunButton.IsEnabled = true; }
    }

    void ShowProblem(string message)
    {
        var target = _profile.AutoProcess ? TestDiff : TestOutput;
        target.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Error");
        target.Text = message;
    }

    /// <summary>"−52% length · within limit": the same word-count measure the safety net uses.</summary>
    string LengthChange(string input, string output)
    {
        static int Words(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        var wi = Words(input);
        if (wi == 0) return "";
        var change = (double)Words(output) / wi - 1;
        var sign = change < 0 ? "−" : "+";
        return $"{sign}{Math.Abs(change):P0} length · within limit";
    }
}
