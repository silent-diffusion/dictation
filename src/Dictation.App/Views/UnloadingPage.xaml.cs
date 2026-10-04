using System.Windows.Controls;

namespace Dictation.App.Views;

public partial class UnloadingPage : UserControl
{
    public UnloadingPage()
    {
        InitializeComponent();
        var s = App.Services.Settings.Current;
        var choices = new List<Choice>
        {
            new("5 minutes", 5), new("10 minutes", 10), new("15 minutes", 15), new("30 minutes", 30),
            new("1 hour", 60), new("2 hours", 120), new("4 hours", 240), new("Never (keep loaded)", 0),
        };
        if (choices.All(c => c.Value != s.UnloadAfterMinutes)) choices.Insert(0, new($"{s.UnloadAfterMinutes} minutes", s.UnloadAfterMinutes));
        AfterBox.ItemsSource = choices;
        DataContext = s;
        StatusText.Text = $"Now: {App.Services.Status.Speech}\n{App.Services.Status.Ai}";
        AutoSave.Hook(this, () => App.Services.Settings.Save());
    }
}
