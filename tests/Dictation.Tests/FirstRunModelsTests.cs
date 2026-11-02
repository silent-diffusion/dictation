using System.Text.Json;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;
using Dictation.Core.Setup;
using Xunit;

namespace Dictation.Tests;

/// <summary>Setup picks models for the hardware on a new install, even though settings.json is written before it runs.</summary>
public class FirstRunModelsTests
{
    [Fact]
    public void New_install_on_a_cpu_pc_gets_the_cpu_models_even_after_an_early_save()
    {
        var path = Path.Combine(Path.GetTempPath(), "oberton-settings-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            // ProfileService saves the settings while the app starts, before the setup window opens.
            new SettingsService(path).Save();
            Assert.True(File.Exists(path));

            var settings = new SettingsService(path);
            Assert.True(RuntimeInstaller.ChooseModels(settings.Current, gpu: false));
            settings.Save();

            var s = new SettingsService(path).Current;
            Assert.Equal("small.en", s.Asr.Model);
            Assert.Equal("cpu", s.Asr.Device);
            Assert.True(s.ModelsChosen);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void A_repair_keeps_the_users_own_models()
    {
        var s = new AppSettings { ModelsChosen = false };
        RuntimeInstaller.ChooseModels(s, gpu: false);
        s.Asr.Model = "medium.en";
        s.Asr.Device = "auto";

        Assert.False(RuntimeInstaller.ChooseModels(s, gpu: false));
        Assert.Equal("medium.en", s.Asr.Model);
        Assert.Equal("auto", s.Asr.Device);
    }

    [Fact]
    public void Settings_from_before_the_flag_count_as_chosen()
    {
        var s = JsonSerializer.Deserialize<AppSettings>("""{ "Asr": { "Model": "distil-large-v3", "Device": "cuda" } }""", JsonStore.Options)!;

        Assert.False(RuntimeInstaller.ChooseModels(s, gpu: false));
        Assert.Equal("distil-large-v3", s.Asr.Model);
        Assert.Equal("cuda", s.Asr.Device);
    }
}
