using System.Windows;
using System.Windows.Media;
using Dictation.Core.Infrastructure;
using Dictation.Core.Setup;

namespace Dictation.App.Views;

/// <summary>First-run download of runtimes and models, with progress. Resumable: Retry skips finished steps.</summary>
public partial class SetupWindow : Window
{
    CancellationTokenSource? _cts;
    bool _running, _done;

    public sealed record PlanItem(string Name, string What);

    public SetupWindow()
    {
        InitializeComponent();
        var gpu = RuntimeInstaller.HasNvidiaGpu();
        var (whisper, llm, _) = RuntimeInstaller.DefaultsFor(gpu);
        Intro.Text = "One download and you can talk into any app. After this, Oberton works offline: " +
                     "no accounts, no cloud, no telemetry.";
        HardwareText.Text = gpu
            ? "NVIDIA graphics card found, so speech runs on the GPU."
            : "No NVIDIA graphics card found, so speech runs on the CPU (a few seconds slower).";
        if (!gpu) HardwareIcon.Data = Geometry.Parse("M 9,3 L 9,10.5 M 9,14 L 9,14.1"); // an "i"-style note instead of a check
        if (!gpu) HardwareIcon.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty, "Ob.Muted");
        PlanList.ItemsSource = new[]
        {
            new PlanItem("Speech engine", gpu ? "faster-whisper + CUDA runtime" : "faster-whisper"),
            new PlanItem("Speech model", whisper),
            new PlanItem("Cleanup model", llm + " via Ollama"),
        };
        PlanText.Text = $"About {RuntimeInstaller.EstimatedDownloadGb(gpu):0.#} GB in total, saved to {AppPaths.Root}." +
                        (gpu ? "" : " On the CPU, expect roughly 5–10 seconds of processing after each dictation.");
        if (File.Exists(AppPaths.PythonExe) || File.Exists(AppPaths.OllamaExe))
            StartButton.Content = "CONTINUE SETUP";
    }

    async void Start_Click(object sender, RoutedEventArgs e)
    {
        if (_done) { DialogResult = true; return; }
        _running = true;
        _cts = new CancellationTokenSource();
        StartButton.IsEnabled = false;
        CancelButton.Content = "CANCEL";
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
            StartButton.Content = "START USING OBERTON";
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
        StartButton.Content = "CONTINUE SETUP";
        StartButton.IsEnabled = true;
        CancelButton.Content = "QUIT";
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
