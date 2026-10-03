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
        Loaded += async (_, _) =>
        {
            var models = await App.Services.Llm.ListModelsAsync();
            ModelBox.ItemsSource = models;
        };
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
        TestOutput.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Muted");
        TestOutput.Text = "Processing…";
        var input = TestInput.Text;
        try
        {
            var result = await App.Services.Llm.ProcessAsync(input, _profile);
            TestOutput.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Text");
            DiffText.Render(TestOutput, WordDiff.Compute(input, result.Text),
                (Brush)FindResource("Ob.DiffRemoved"), (Brush)FindResource("Ob.DiffAdded"));
            TestMeta.Text = !result.SafetyNet ? LengthChange(input, result.Text)
                : result.Modified ? "safety net: some parts kept as spoken" : "safety net: original kept";
            if (result.Warning != null && !result.SafetyNet) TestMeta.Text = result.Warning;
        }
        catch (UserFacingException ex) { ShowProblem(ex.Message); }
        catch (Exception ex) { Log.Error("Profile test failed", ex); ShowProblem("Something went wrong. See the log."); }
        finally { RunButton.IsEnabled = true; }
    }

    void ShowProblem(string message)
    {
        TestOutput.SetResourceReference(TextBlock.ForegroundProperty, "Ob.Error");
        TestOutput.Text = message;
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
