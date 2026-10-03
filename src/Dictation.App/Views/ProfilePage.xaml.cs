using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;

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

    void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (App.Services.Profiles.Profiles.Count <= 1)
        {
            MessageBox.Show("You need at least one profile.", "Local Dictation", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (MessageBox.Show($"Delete the profile \"{_profile.Name}\"?", "Local Dictation", MessageBoxButton.YesNo,
                MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        App.Services.Profiles.Delete(_profile);
    }

    async void Run_Click(object sender, RoutedEventArgs e)
    {
        RunButton.IsEnabled = false;
        TestOutput.Text = "Processing…";
        try
        {
            var result = await App.Services.Llm.ProcessAsync(TestInput.Text, _profile);
            TestOutput.Text = result.Text + (result.Warning != null ? $"\n\n⚠ {result.Warning}" : "");
        }
        catch (UserFacingException ex) { TestOutput.Text = "⚠ " + ex.Message; }
        catch (Exception ex) { Log.Error("Profile test failed", ex); TestOutput.Text = "⚠ Something went wrong. See the log."; }
        finally { RunButton.IsEnabled = true; }
    }
}
