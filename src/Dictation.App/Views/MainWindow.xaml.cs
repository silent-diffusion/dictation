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
        s.Settings.Changed += UpdateCycleHint;
        UpdateCycleHint();
        ProfileList.ItemsSource = s.Profiles.Profiles;
        ProfileList.SelectedItem = s.Profiles.Active;
        s.Profiles.Profiles.CollectionChanged += (_, e) =>
        {
            if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Remove && ProfileList.SelectedItem == null
                && Host.Content is ProfilePage)
                ProfileList.SelectedItem = s.Profiles.Active;
        };
        Icon = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(
            Services.TrayIcon.CreateIcon().Handle, Int32Rect.Empty, System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions());
    }

    void UpdateDots()
    {
        var s = App.Services.Status;
        // Resource references (not brushes) so the dots follow a theme switch.
        SpeechDot.SetResourceReference(Shape.FillProperty, s.SpeechOk ? "Ob.Ok" : "Ob.Busy");
        AiDot.SetResourceReference(Shape.FillProperty, s.AiOk ? "Ob.Ok" : "Ob.Busy");
    }

    void UpdateCycleHint()
    {
        var hotkey = App.Services.Settings.Current.CycleProfileHotkey;
        CycleHint.Text = string.IsNullOrEmpty(hotkey) ? "" : hotkey + " cycles";
    }

    void ProfileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProfileList.SelectedItem is not Profile p) return;
        NavList.SelectedIndex = -1;
        Host.Content = new ProfilePage(p);
    }

    void NavList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NavList.SelectedItem is not ListBoxItem item) return;
        ProfileList.SelectedItem = null;
        Host.Content = item.Tag switch
        {
            "General" => new GeneralPage(),
            "Appearance" => new AppearancePage(),
            "Hotkeys" => new HotkeysPage(),
            "Speech" => new SpeechPage(),
            "Models" => new ModelsPage(),
            "Audio" => new AudioPage(),
            "History" => new HistoryPage(),
            "About" => new AboutPage(),
            _ => (object)new AdvancedPage(),
        };
    }

    public void ShowPage(string tag)
    {
        foreach (var o in NavList.Items)
            if (o is ListBoxItem item && (string)item.Tag == tag) { NavList.SelectedItem = item; return; }
    }

    void NewProfile_Click(object sender, RoutedEventArgs e)
    {
        var p = App.Services.Profiles.Create();
        ProfileList.SelectedItem = p;
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

