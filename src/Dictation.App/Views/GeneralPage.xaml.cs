using System.Windows.Controls;
using Dictation.Core.Settings;

namespace Dictation.App.Views;

public partial class GeneralPage : UserControl
{
    public GeneralPage()
    {
        InitializeComponent();
        InsertionBox.ItemsSource = Enum.GetValues<InsertionMode>();
        DataContext = App.Services.Settings.Current;
        AutoSave.Hook(this, () => App.Services.Settings.Save());
    }
}
