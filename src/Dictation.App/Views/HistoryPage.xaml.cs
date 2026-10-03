using System.Windows;
using System.Windows.Controls;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;

namespace Dictation.App.Views;

public partial class HistoryPage : UserControl
{
    public HistoryPage()
    {
        InitializeComponent();
        List.ItemsSource = App.Services.Controller.History;
        if (List.Items.Count > 0) List.SelectedIndex = 0;
    }

    SessionRecord? Current => List.SelectedItem as SessionRecord;

    void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        RawBox.Text = Current?.Raw ?? "";
        ProcBox.Text = Current?.Processed ?? "";
        Info.Text = Current == null ? "" : Current.Inserted ? "Inserted into " + Current.Target + "." : "Not inserted.";
    }

    void CopyRaw_Click(object sender, RoutedEventArgs e) { if (Current != null) Clipboard.SetText(Current.Raw); }
    void CopyProc_Click(object sender, RoutedEventArgs e) { if (Current != null) Clipboard.SetText(Current.Processed); }

    async void InsertRaw_Click(object sender, RoutedEventArgs e)
    {
        if (Current == null) return;
        try { await App.Services.Controller.InsertIntoLastTargetAsync(Current.Raw); }
        catch (UserFacingException ex) { Info.Text = "⚠ " + ex.Message; }
    }
}
