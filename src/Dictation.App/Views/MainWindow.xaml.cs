using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Shapes;
using System.Windows.Threading;
using Dictation.Core.Settings;

namespace Dictation.App.Views;

public partial class MainWindow : Window
{
    bool _forceClose;

    public MainWindow()
    {
        InitializeComponent();
        var s = App.Services;
        DataContext = s.Status;
        s.Status.PropertyChanged += (_, _) => UpdateDots();
        UpdateDots();
        s.Settings.Changed += UpdatePrivacy;
        UpdatePrivacy();
        Icon = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(
            Services.TrayIcon.CreateIcon().Handle, Int32Rect.Empty, System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions());
        NavList.SelectedItem = DashboardItem;
    }

    void UpdateDots()
    {
        var s = App.Services.Status;
        // Resource references (not brushes) so the dots follow a theme switch.
        SpeechDot.SetResourceReference(Shape.FillProperty, s.SpeechOk ? "Ob.Ok" : "Ob.Busy");
        AiDot.SetResourceReference(Shape.FillProperty, s.AiOk ? "Ob.Ok" : "Ob.Busy");
    }

    void UpdatePrivacy() => PrivacyText.Text = App.Services.Settings.Current.Cloud.KeepOffline
        ? "Everything stays on this PC."
        : "Cloud AI allowed: profiles with a cloud model send their text to it.";

    void NavList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NavList.SelectedItem is not ListBoxItem { Tag: string tag }) return;
        Host.Content = tag switch
        {
            "SpeechToText" => new SpeechToTextPage(),
            "ReadAloud" => new ReadAloudPage(),
            "History" => new HistoryPage(),
            "Settings" => new SettingsPage(),
            _ => (object)new DashboardPage(),
        };
    }

    /// <summary>Open a section ("Dashboard", "SpeechToText", "ReadAloud", "History") or a settings section by its tag
    /// (e.g. "About" from the tray's update check).</summary>
    public void ShowPage(string tag)
    {
        var item = NavList.Items.OfType<ListBoxItem>().FirstOrDefault(i => i.Tag as string == tag);
        if (item != null) { NavList.SelectedItem = item; return; }
        NavList.SelectedItem = SettingsItem;
        if (Host.Content is SettingsPage settings) settings.Show(tag);
    }

    /// <summary>Speech to text, with a profile open.</summary>
    public void ShowProfile(Profile p)
    {
        NavList.SelectedItem = SpeechItem;
        if (Host.Content is SpeechToTextPage page) page.Select(p);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_forceClose && App.Services.Settings.Current.MinimizeToTray)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnClosing(e);
        if (!_forceClose) { e.Cancel = true; ((App)Application.Current).Quit(); }
    }

    public void ForceClose()
    {
        _forceClose = true;
        Close();
    }
}

/// <summary>Debounced auto-save: any edit inside a page persists shortly after, so there is no Save button.</summary>
public static class AutoSave
{
    public static void Hook(FrameworkElement root, Action save)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        var armed = false;
        timer.Tick += (_, _) => { timer.Stop(); save(); };
        void Poke(object s, RoutedEventArgs e) { if (armed) { timer.Stop(); timer.Start(); } }

        root.AddHandler(System.Windows.Controls.Primitives.TextBoxBase.TextChangedEvent, new TextChangedEventHandler(Poke));
        root.AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(Poke));
        root.AddHandler(Selector.SelectionChangedEvent, new SelectionChangedEventHandler(Poke));
        root.AddHandler(RangeBase.ValueChangedEvent, new RoutedPropertyChangedEventHandler<double>((s, e) => Poke(s, e)));
        // Ignore the change events produced by the initial data binding.
        root.Loaded += (_, _) => root.Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, () => armed = true);
        root.Unloaded += (_, _) => { if (timer.IsEnabled) { timer.Stop(); save(); } armed = false; };
    }
}

