using System.Windows;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;

namespace Dictation.App.Views;

/// <summary>First-run download of runtimes and models, with progress. Resumable: Retry skips finished steps.</summary>
public partial class SetupWindow : Window
{
    CancellationTokenSource? _cts;
    bool _running, _done;

    public SetupWindow()
    {
        InitializeComponent();
        var gpu = RuntimeInstaller.HasNvidiaGpu();
        var (whisper, llm, _) = RuntimeInstaller.DefaultsFor(gpu);
        Intro.Text =
            "Local Dictation runs entirely on this computer. Before first use it needs to download its speech engine, " +
            "AI runtime and models. This happens once; afterwards no internet connection is needed.";
        HardwareText.Text = gpu ? "NVIDIA graphics card found — using GPU acceleration." : "No NVIDIA graphics card found — using the CPU.";
        PlanText.Text =
            $"Downloads about {RuntimeInstaller.EstimatedDownloadGb(gpu):0.#} GB into {AppPaths.Root}. " +
            $"Speech model: {whisper}. AI model: {llm}." +
            (gpu ? "" : " On the CPU, expect roughly 5–10 seconds of processing after each dictation. You can pick faster or more accurate models later in Settings.");
        if (File.Exists(AppPaths.PythonExe) || File.Exists(AppPaths.OllamaExe))
            StartButton.Content = "Continue setup";
    }

    async void Start_Click(object sender, RoutedEventArgs e)
    {
        if (_done) { DialogResult = true; return; }
        _running = true;
        _cts = new CancellationTokenSource();
        StartButton.IsEnabled = false;
        CancelButton.Content = "Cancel";
        ErrorText.Visibility = Visibility.Collapsed;
        ProgressPanel.Visibility = Visibility.Visible;

        var progress = new Progress<SetupProgress>(p =>
        {
            StepText.Text = $"Step {p.Step} of {p.TotalSteps}: {p.Title}";
            Bar.IsIndeterminate = p.Fraction == null;
            if (p.Fraction is { } f) Bar.Value = f;
            DetailText.Text = p.Detail + (p.Fraction is { } g && g < 1 ? $"  ({g:P0})" : "");
        });

        try
        {
            await new RuntimeInstaller(App.Services.Settings, App.Services.OllamaHost).RunAsync(progress, _cts.Token);
            _done = true;
            StepText.Text = "All set!";
            DetailText.Text = $"Press {App.Services.Settings.Current.Hotkey} in any app to start dictating, and press it again to stop.";
            Bar.IsIndeterminate = false;
            Bar.Value = 1;
            StartButton.Content = "Start using Local Dictation";
            StartButton.IsEnabled = true;
            CancelButton.Visibility = Visibility.Collapsed;
        }
        catch (OperationCanceledException)
        {
            ShowError("Setup was cancelled. Click Continue setup to pick up where it left off.");
        }
        catch (UserFacingException ex) { ShowError(ex.Message); }
        catch (Exception ex)
        {
            Log.Error("Setup failed", ex);
            ShowError("Setup failed unexpectedly: " + ex.Message + "\nDetails are in " + AppPaths.LogDir);
        }
        finally { _running = false; }
    }

    void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
        Bar.IsIndeterminate = false;
        StartButton.Content = "Continue setup";
        StartButton.IsEnabled = true;
        CancelButton.Content = "Quit";
    }

    void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (_running) { _cts?.Cancel(); return; }
        DialogResult = false;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        _cts?.Cancel();
        base.OnClosing(e);
    }
}
