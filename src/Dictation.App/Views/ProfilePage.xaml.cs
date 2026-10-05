using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
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
        Loaded += async (_, _) =>
        {
            var models = await App.Services.Llm.ListModelsAsync();
            // Local models first; cloud models (sent only while "Keep everything offline" is off) after them.
            ModelBox.ItemsSource = models.Concat(CloudModels.Catalog(App.Services.Settings.Current.Cloud).Select(c => c.Id)).ToList();
        };
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
            TestOutput.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            TestOutput.Text = result.Text;
            TestMeta.Text = !result.SafetyNet ? LengthChange(input, result.Text)
                : result.Modified ? "safety net: some parts kept as spoken" : "safety net: original kept";
            if (result.Warning != null && !result.SafetyNet) TestMeta.Text = result.Warning;
            if (!_profile.AutoProcess) TestMeta.Text = "";
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
