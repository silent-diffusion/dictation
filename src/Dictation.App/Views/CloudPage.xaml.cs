using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Text;

namespace Dictation.App.Views;

public partial class CloudPage : UserControl
{
    public CloudPage()
    {
        InitializeComponent();
        DataContext = App.Services.Settings.Current;
        AutoSave.Hook(this, () => App.Services.Settings.Save());
        ShowStatus();
    }

    void ShowStatus()
    {
        var c = App.Services.Settings.Current.Cloud;
        AnthropicStatus.Text = c.AnthropicKey != null ? "A key is saved (encrypted)." : "No key saved.";
        OpenAiStatus.Text = c.OpenAiKey != null ? "A key is saved (encrypted)." : "No key saved.";
    }

    void Offline_Click(object sender, RoutedEventArgs e) => App.Services.Settings.Save();

    void SaveAnthropic_Click(object sender, RoutedEventArgs e) => SaveKey(AnthropicKey, k => App.Services.Settings.Current.Cloud.AnthropicKey = k);
    void SaveOpenAi_Click(object sender, RoutedEventArgs e) => SaveKey(OpenAiKey, k => App.Services.Settings.Current.Cloud.OpenAiKey = k);
    void RemoveAnthropic_Click(object sender, RoutedEventArgs e) { App.Services.Settings.Current.Cloud.AnthropicKey = null; Done(); }
    void RemoveOpenAi_Click(object sender, RoutedEventArgs e) { App.Services.Settings.Current.Cloud.OpenAiKey = null; Done(); }

    void SaveKey(PasswordBox box, Action<string?> set)
    {
        if (string.IsNullOrWhiteSpace(box.Password)) return;
        set(SecretStore.Protect(box.Password));
        box.Clear();
        Done();
    }

    void Done()
    {
        App.Services.Settings.Save();
        ShowStatus();
    }
}
