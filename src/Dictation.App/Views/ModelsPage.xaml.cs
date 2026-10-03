using System.Windows;
using System.Windows.Controls;

namespace Dictation.App.Views;

public partial class ModelsPage : UserControl
{
    public ModelsPage()
    {
        InitializeComponent();
        DataContext = App.Services.Settings.Current;
        AutoSave.Hook(this, () => App.Services.Settings.Save());
        StatusText.Text = App.Services.Status.Ai;
        App.Services.Status.PropertyChanged += (_, _) => StatusText.Text = App.Services.Status.Ai;
        Loaded += async (_, _) => await ReloadAsync();
    }

    async Task ReloadAsync()
    {
        InstalledText.Text = "Checking…";
        var models = await App.Services.Llm.ListModelsAsync();
        ModelBox.ItemsSource = models;
        InstalledText.Text = models.Count == 0
            ? "None found. Is the AI runtime running? Run scripts\\setup.ps1 if it isn't installed."
            : string.Join("\n", models.Select(m => "•  " + m));
    }

    async void Refresh_Click(object sender, RoutedEventArgs e) => await ReloadAsync();

    async void Load_Click(object sender, RoutedEventArgs e)
    {
        App.Services.Settings.Save();
        await App.Services.Llm.WarmUpAsync(null);
        await ReloadAsync();
    }
}
