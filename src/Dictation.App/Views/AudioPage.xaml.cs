using System.Windows.Controls;
using Dictation.Core.Audio;
using Dictation.Core.Infrastructure;
using Dictation.Core.Session;

namespace Dictation.App.Views;

public partial class AudioPage : UserControl
{
    const string DefaultLabel = "(System default microphone)";
    MicCapture? _meter;
    bool _loading = true;

    public AudioPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            var devices = App.Services.Mic.ListDevices();
            MicBox.Items.Add(DefaultLabel);
            foreach (var d in devices) MicBox.Items.Add(d);
            var cur = App.Services.Settings.Current.MicrophoneName;
            MicBox.SelectedItem = cur != null && devices.Contains(cur) ? cur : DefaultLabel;
            _loading = false;
            StartMeter();
        };
        Unloaded += (_, _) => { _meter?.Dispose(); _meter = null; };
    }

    void StartMeter()
    {
        _meter?.Dispose();
        _meter = null;
        if (App.Services.Controller.State != DictationState.Idle) return; // don't fight an active dictation
        try
        {
            _meter = new MicCapture();
            _meter.LevelChanged += l => Dispatcher.BeginInvoke(() => Level.Value = l);
            var name = MicBox.SelectedItem as string;
            _meter.Start(name == DefaultLabel ? null : name);
        }
        catch (UserFacingException ex) { Hint.Text = ex.Message; }
    }

    void Mic_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        var name = MicBox.SelectedItem as string;
        App.Services.Settings.Current.MicrophoneName = name == DefaultLabel ? null : name;
        App.Services.Settings.Save();
        StartMeter();
    }
}
