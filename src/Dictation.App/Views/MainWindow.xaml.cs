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
        SetSidebar(!s.Settings.Current.SidebarCollapsed, animate: false, save: false);
        PreviewKeyDown += (_, e) =>
        {
            var mods = System.Windows.Input.Keyboard.Modifiers;
            if (e.Key == System.Windows.Input.Key.B && mods == System.Windows.Input.ModifierKeys.Control)
            {
                SetSidebar(!_open);
                e.Handled = true;
            }
            else if (e.SystemKey == System.Windows.Input.Key.Left && mods == System.Windows.Input.ModifierKeys.Alt)
            {
                GoBack();
                e.Handled = true;
            }
        };
        MouseDown += (_, e) => { if (e.ChangedButton == System.Windows.Input.MouseButton.XButton1) GoBack(); }; // the mouse's back button
    }

    // ===== sidebar: slides away to the left; the menu button morphs ☰ ⇄ ✕ =====

    const double SidebarWidth = 268;
    bool _open = true;
    double _shut; // 0 = sidebar fully shown, 1 = fully away
    EventHandler? _slide;

    void Menu_Click(object sender, RoutedEventArgs e) => SetSidebar(!_open);

    /// <summary>Show or fold away the sidebar; folded, the page gets the whole window.</summary>
    void SetSidebar(bool open, bool animate = true, bool save = true)
    {
        _open = open;
        MenuButton.ToolTip = (open ? "Hide the menu" : "Show the menu") + " (Ctrl+B)";
        System.Windows.Automation.AutomationProperties.SetName(MenuButton, open ? "Hide the menu" : "Show the menu");
        MorphMenuIcon(open, animate);
        SlideSidebar(open ? 0 : 1, animate);
        if (!save) return;
        var settings = App.Services.Settings;
        settings.Current.SidebarCollapsed = !open;
        settings.Save();
    }

    /// <summary>Move the sidebar and the page together, frame by frame (ease-out, about a quarter second).</summary>
    void SlideSidebar(double to, bool animate)
    {
        if (_slide != null) { System.Windows.Media.CompositionTarget.Rendering -= _slide; _slide = null; }
        Sidebar.Visibility = Visibility.Visible;
        if (!animate) { Place(to); return; }
        var from = _shut;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        _slide = (_, _) =>
        {
            var p = Math.Min(1, clock.Elapsed.TotalMilliseconds / 260);
            Place(from + (to - from) * (1 - Math.Pow(1 - p, 3)));
            if (p < 1) return;
            System.Windows.Media.CompositionTarget.Rendering -= _slide;
            _slide = null;
        };
        System.Windows.Media.CompositionTarget.Rendering += _slide;
    }

    /// <summary>Back's offset while the sidebar is open: from its spot beside the menu button to the sidebar's right
    /// edge, after the logo (menu · Oberton · Back).</summary>
    const double BackOpenShift = SidebarWidth - 14 - 36 - (12 + 36 + 6);

    void Place(double shut)
    {
        _shut = shut;
        SidebarSlide.X = -SidebarWidth * shut;
        BackSlide.X = BackOpenShift * (1 - shut);
        // Folded, the menu and Back buttons sit in a bar across the top and every page starts below it.
        TopBar.Visibility = shut > 0 ? Visibility.Visible : Visibility.Collapsed;
        TopBar.Opacity = shut;
        Host.Margin = new Thickness(SidebarWidth * (1 - shut), TopBarHeight * shut, 0, 0);
        Sidebar.Visibility = shut >= 1 ? Visibility.Collapsed : Visibility.Visible; // off screen: out of the tab order too
    }

    const double TopBarHeight = 64;

    /// <summary>Three bars ⇄ a cross: the top and bottom bars meet in the middle and turn ±45°, the middle one fades.</summary>
    void MorphMenuIcon(bool cross, bool animate)
    {
        var d = new Duration(TimeSpan.FromMilliseconds(animate ? 240 : 0));
        var ease = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseInOut };
        void To(System.Windows.Media.Animation.IAnimatable target, DependencyProperty prop, double value) =>
            target.BeginAnimation(prop, new System.Windows.Media.Animation.DoubleAnimation(value, d) { EasingFunction = ease });
        To(Bar1Turn, System.Windows.Media.RotateTransform.AngleProperty, cross ? 45 : 0);
        To(Bar1Move, System.Windows.Media.TranslateTransform.YProperty, cross ? 6 : 0);
        To(Bar3Turn, System.Windows.Media.RotateTransform.AngleProperty, cross ? -45 : 0);
        To(Bar3Move, System.Windows.Media.TranslateTransform.YProperty, cross ? -6 : 0);
        To(Bar2, OpacityProperty, cross ? 0 : 1);
    }

    // ===== Back: the pages (and Settings sections) visited, most recent last =====

    readonly List<string> _visited = new();
    string _here = "Dashboard";
    bool _goingBack;
    string? _openSection; // the Settings section to open when the Settings page is created

    /// <summary>Note that <paramref name="place"/> ("History", "Settings/Appearance"…) is now shown.</summary>
    void Visit(string place)
    {
        if (place == _here) return;
        if (!_goingBack)
        {
            _visited.Add(_here);
            if (_visited.Count > 50) _visited.RemoveAt(0);
        }
        _here = place;
        // Back is everywhere except the dashboard (it is where the app starts).
        BackButton.Visibility = place == "Dashboard" ? Visibility.Collapsed : Visibility.Visible;
        Place(_shut); // the folded page's layout depends on the page and on whether Back shows
    }

    void Back_Click(object sender, RoutedEventArgs e) => GoBack();

    /// <summary>To the page shown before this one (the dashboard if there is none).</summary>
    void GoBack()
    {
        if (_here == "Dashboard") return;
        var target = "Dashboard";
        while (_visited.Count > 0)
        {
            target = _visited[^1];
            _visited.RemoveAt(_visited.Count - 1);
            if (target != _here) break;
            target = "Dashboard";
        }
        _goingBack = true;
        try { ShowPage(target.StartsWith("Settings/") ? target["Settings/".Length..] : target); }
        finally { _goingBack = false; }
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
        if (tag == "Settings")
        {
            var settings = new SettingsPage(_openSection ?? "General");
            _openSection = null;
            settings.SectionShown += section => Visit("Settings/" + section);
            Host.Content = settings;
            Visit("Settings/" + settings.Section);
            Place(_shut);
            return;
        }
        Host.Content = tag switch
        {
            "SpeechToText" => new SpeechToTextPage(),
            "ReadAloud" => new ReadAloudPage(),
            "History" => new HistoryPage(),
            _ => (object)new DashboardPage(),
        };
        Visit(tag);
        Place(_shut); // fit the new page to the sidebar's state
    }

    /// <summary>Open a section ("Dashboard", "SpeechToText", "ReadAloud", "History") or a settings section by its tag
    /// (e.g. "About" from the tray's update check).</summary>
    public void ShowPage(string tag)
    {
        var item = NavList.Items.OfType<ListBoxItem>().FirstOrDefault(i => i.Tag as string == tag);
        if (item != null) { NavList.SelectedItem = item; return; }
        if (Host.Content is SettingsPage settings) { settings.Show(tag); return; }
        _openSection = tag; // a new Settings page opens straight on this section
        NavList.SelectedItem = SettingsItem;
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

