using System.Text.Json;
using System.Windows;
using Dictation.App.Services;
using Dictation.App.Views;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;
using Dictation.Core.Setup;

namespace Dictation.App;

public partial class App : Application
{
    public static AppServices Services { get; private set; } = null!;
    public static HotkeyManager Hotkeys { get; private set; } = null!;
    /// <summary>Set when a hotkey could not be registered; shown on the Hotkeys page.</summary>
    public static string? HotkeyError { get; private set; }

    const int HkToggle = 1, HkCycle = 2, HkEscape = 3;
    Mutex? _single;
    EventWaitHandle? _showEvent;
    TrayIcon? _tray;
    OverlayWindow? _overlay;
    MainWindow? _main;
    string _lastHotkeys = "", _lastAsr = "";
    bool _quitting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _single = new Mutex(true, "LocalDictation.SingleInstance", out var first);
        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "LocalDictation.Show");
        if (!first)
        {
            _showEvent.Set(); // ask the running instance to show its window
            Shutdown();
            return;
        }
        new Thread(() =>
        {
            while (_showEvent.WaitOne()) Dispatcher.BeginInvoke(ShowMain);
        }) { IsBackground = true }.Start();

        DispatcherUnhandledException += (_, a) =>
        {
            Log.Error("Unhandled UI exception", a.Exception);
            a.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, a) => { Log.Error("Unobserved task exception", a.Exception); a.SetObserved(); };

        Log.Info("=== Oberton starting ===");
        Services = new AppServices();
        var s = Services;
        ThemeManager.Apply(s.Settings.Current.Theme);

        // First run (or an interrupted setup): download the runtimes and models before anything else.
        if (!RuntimeInstaller.IsInstalled)
        {
            var setup = new SetupWindow();
            if (setup.ShowDialog() != true)
            {
                Log.Info("Setup not completed; exiting");
                s.OllamaHost.Stop();
                Shutdown();
                return;
            }
        }

        Hotkeys = new HotkeyManager();
        _overlay = new OverlayWindow();
        _main = new MainWindow();
        _tray = new TrayIcon(s.Profiles, () => s.Controller.Toggle(), ShowMain, () => ShowPage("About"), Quit);

        WireController();
        ApplyHotkeys();
        _lastAsr = JsonSerializer.Serialize(s.Settings.Current.Asr);
        s.Settings.Changed += OnSettingsChanged;
        s.Profiles.ActiveChanged += () =>
        {
            _tray?.SetTooltip($"{AppInfo.Name} · {s.Profiles.Active.Name}");
            _ = s.Llm.WarmUpAsync(s.Profiles.Active.Model);
        };
        _tray.SetTooltip($"{AppInfo.Name} · {s.Profiles.Active.Name}");
        Autostart.Apply(s.Settings.Current.StartWithWindows);

        var minimized = e.Args.Contains("--minimized");
        if (!minimized) ShowMain();

        // Warm both models in the background so the first hotkey press is instant.
        _ = Task.Run(async () =>
        {
            try { await s.Speech.InitializeAsync(); }
            catch (UserFacingException ex)
            {
                Log.Warn("Speech init: " + ex.Message);
                s.Controller_NoticeBridge(ex.Message);
            }
            catch (Exception ex) { Log.Error("Speech init failed", ex); }
        });
        _ = s.Llm.WarmUpAsync(s.Profiles.Active.Model);

        if (s.Settings.Current.CheckUpdatesOnStartup) _ = CheckForUpdatesQuietlyAsync();
    }

    /// <summary>Opt-in startup check: only tells the user; installing is always their click.</summary>
    async Task CheckForUpdatesQuietlyAsync()
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(20)); // let the models load first
            var info = await new UpdateService().CheckAsync();
            if (info == null) return;
            AvailableUpdate = info;
            _overlay?.ShowMessage($"{AppInfo.Name} {info.Version.ToString(3)} is available. Open Settings > About & updates to install it.", NoticeLevel.Info);
        }
        catch (Exception ex) { Log.Warn("Startup update check failed: " + ex.Message); }
    }

    /// <summary>Set when a startup check found a newer release.</summary>
    public static UpdateInfo? AvailableUpdate { get; set; }

    /// <summary>Appearance page: show the overlay at its (new) position for a moment.</summary>
    public void PreviewOverlay() => _overlay?.ShowPositionPreview();

    public void ShowPage(string tag)
    {
        ShowMain();
        _main?.ShowPage(tag);
    }

    void WireController()
    {
        var c = Services.Controller;
        var overlay = _overlay!;
        overlay.CancelRequested += () => c.Cancel();
        overlay.InsertRequested += () => c.Toggle(); // in preview, the hotkey and the Insert button do the same thing
        overlay.InsertRawRequested += () => c.InsertRawInstead();
        c.StateChanged += state =>
        {
            if (state == DictationState.Confirming)
            {
                var err = Hotkeys.Register(HkEscape, "Escape", () => c.Cancel());
                if (err != null) Log.Warn(err);
            }
            else Hotkeys.Unregister(HkEscape);

            if (!Services.Settings.Current.ShowOverlay && state != DictationState.Confirming) return;
            var profile = Services.Profiles.Active;
            var model = string.IsNullOrWhiteSpace(profile.Model) ? Services.Settings.Current.Llm.DefaultModel : profile.Model;
            overlay.ShowState(state, profile.Name, c.PendingRaw, c.PreviewText, model, c.IsLive);
        };
        c.Inserted += r => { if (Services.Settings.Current.ShowOverlay) overlay.ShowReceipt(r); };
        c.AudioLevel += l => overlay.SetLevel(l);
        c.Notice += (msg, level) => overlay.ShowMessage(msg, level);
    }

    void ApplyHotkeys()
    {
        var st = Services.Settings.Current;
        _lastHotkeys = st.Hotkey + "|" + st.CycleProfileHotkey;
        _overlay?.SetHotkeyText(st.Hotkey);
        var errors = new List<string>();
        var e1 = Hotkeys.Register(HkToggle, st.Hotkey, () => Services.Controller.Toggle());
        if (e1 != null) errors.Add(e1);
        var e2 = Hotkeys.Register(HkCycle, st.CycleProfileHotkey, () =>
        {
            var profiles = Services.Profiles;
            profiles.CycleActive();
            _overlay?.ShowProfile(profiles.Active.Name, profiles.Profiles.IndexOf(profiles.Active), profiles.Profiles.Count);
        });
        if (e2 != null) errors.Add(e2);
        HotkeyError = errors.Count == 0 ? null : string.Join("\n", errors);
        if (HotkeyError != null)
        {
            Log.Warn(HotkeyError);
            _overlay?.ShowMessage(HotkeyError, NoticeLevel.Error);
        }
    }

    void OnSettingsChanged()
    {
        var st = Services.Settings.Current;
        if (_lastHotkeys != st.Hotkey + "|" + st.CycleProfileHotkey) ApplyHotkeys();
        Autostart.Apply(st.StartWithWindows);
        ThemeManager.Apply(st.Theme);
    }

    /// <summary>Called by the Speech page when the user presses "Apply and restart engine".</summary>
    public static async Task RestartSpeechAsync()
    {
        try { await Services.Speech.RestartAsync(); }
        catch (UserFacingException ex) { Services.Status.Speech = "Speech: " + ex.Message; }
    }

    public void ShowMain()
    {
        if (_main == null) return;
        if (!_main.IsVisible) _main.Show();
        if (_main.WindowState == WindowState.Minimized) _main.WindowState = WindowState.Normal;
        _main.Activate();
    }

    public void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        Hotkeys.Dispose();
        _tray?.Dispose();
        Services.Mic.Dispose();
        _ = Services.Speech.DisposeAsync();
        Services.OllamaHost.Stop();
        _main?.ForceClose();
        Log.Info("=== Oberton exiting ===");
        Shutdown();
    }
}

static class ServiceExtensions
{
    /// <summary>Surface a startup problem on the overlay (UI thread).</summary>
    public static void Controller_NoticeBridge(this AppServices s, string message) =>
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            ((App)Application.Current).ShowMain();
            System.Windows.MessageBox.Show(message, AppInfo.Name, MessageBoxButton.OK, MessageBoxImage.Warning);
        });
}
