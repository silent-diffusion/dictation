using Dictation.Core.Notes;
using Dictation.Core.Text;
using Xunit;

namespace Dictation.Tests;

public class NotesModelTests
{
    const long GB = 1024L * 1024 * 1024;

    static readonly LocalModel Qwen3B = new("qwen2.5:3b", 3.1, (long)(1.9 * GB), "qwen2");
    static readonly LocalModel Qwen7B = new("qwen2.5:7b", 7.6, (long)(4.7 * GB), "qwen2");
    static readonly LocalModel Qwen3_4B = new("qwen3:4b-instruct-2507-q4_K_M", 4.0, (long)(2.5 * GB), "qwen3");
    static readonly LocalModel Big = new("qwen2.5:14b", 14.8, 9 * GB, "qwen2");
    static readonly LocalModel Embed = new("nomic-embed-text", 0.137, (long)(0.27 * GB), "nomic-bert");
    static readonly LocalModel[] Installed = { Qwen3B, Qwen7B, Qwen3_4B, Big, Embed };

    [Theory]
    [InlineData("7.6B", 0, 7.6)]
    [InlineData("494.03M", 0, 0.49403)]
    [InlineData("27B", 0, 27)]
    [InlineData(null, 4_800_000_000L, 8.0)]
    public void Parameter_sizes_are_read_or_estimated(string? size, long bytes, double billions) =>
        Assert.Equal(billions, LocalModel.ParseBillions(size, bytes), 3);

    [Fact]
    public void The_best_is_the_largest_that_fits_the_gpu()
    {
        Assert.Equal(Qwen7B, NotesModels.PickBest(Installed, 6 * GB)); // this PC: a 6 GB RTX 3060
        Assert.Equal(Big, NotesModels.PickBest(Installed, 12 * GB));
        Assert.Equal(Qwen3_4B, NotesModels.PickBest(Installed, 4 * GB));
        Assert.Equal(Qwen3_4B, NotesModels.PickBest(Installed, null)); // no GPU: up to 4.5B
        Assert.Equal(Qwen3B, NotesModels.PickBest(new[] { Qwen3B, Embed }, null));
        Assert.Equal(Qwen3B, NotesModels.PickBest(new[] { Big, Qwen3B }, 1 * GB)); // nothing fits: the smallest
        Assert.Null(NotesModels.PickBest(new[] { Embed }, 6 * GB)); // an embedding model can't write
    }

    [Fact]
    public void An_ollama_cloud_model_is_never_the_best()
    {
        var cloud = new LocalModel("gpt-oss:120b-cloud", 116.8, 384, "gptoss"); // listed like an installed one
        Assert.Equal(Qwen7B, NotesModels.PickBest(new[] { cloud, Qwen7B }, 6 * GB));
        Assert.Null(NotesModels.PickBest(new[] { cloud }, 6 * GB));
    }

    static Task<IReadOnlyList<LocalModel>> List() => Task.FromResult<IReadOnlyList<LocalModel>>(Installed);

    [Fact]
    public async Task The_setting_resolves_to_a_model()
    {
        Assert.Equal("qwen2.5:7b", (await NotesModels.ResolveAsync("", "qwen3:4b", List, 6 * GB)).Model);
        Assert.Equal("qwen3:4b", (await NotesModels.ResolveAsync(NotesModels.Active, "qwen3:4b", List, 6 * GB)).Model);
        Assert.Equal("qwen2.5:3b", (await NotesModels.ResolveAsync("qwen2.5:3b", "qwen3:4b", List, 6 * GB)).Model);
        Assert.Equal("qwen2.5:7b", (await NotesModels.ResolveAsync("llama3.2:3b", "qwen3:4b", List, 6 * GB)).Model); // not installed
        Assert.Equal("openai:gpt-4o-mini", (await NotesModels.ResolveAsync("openai:gpt-4o-mini", "qwen3:4b", List, 6 * GB)).Model);
        Assert.Equal("qwen3:4b", (await NotesModels.ResolveAsync("", "qwen3:4b", () => throw new InvalidOperationException("down"), 6 * GB)).Model);
        Assert.Equal("qwen3:4b", (await NotesModels.ResolveAsync("", "qwen3:4b",
            () => Task.FromResult<IReadOnlyList<LocalModel>>(Array.Empty<LocalModel>()), 6 * GB)).Model);
    }

    static readonly LocalModel Qwen30A3 = new("qwen3:30b-a3b-instruct-2507-q4_K_M", 30.5, (long)(17.3 * GB), "qwen3moe");

    [Fact]
    public void A_mixture_of_experts_counts_its_working_parameters()
    {
        Assert.True(Qwen30A3.IsMixture);
        Assert.Equal(3, Qwen30A3.ActiveBillions);
        Assert.Equal(3.3, new LocalModel("qwen3:30b", 30.5, 19 * GB, "qwen3moe").ActiveBillions, 1); // no "a3b" in the name
        Assert.Equal(22, new LocalModel("qwen3:235b-a22b-instruct-2507-q4_K_M", 235, 142 * GB, "qwen3moe").ActiveBillions);
        Assert.False(Qwen7B.IsMixture);
        Assert.Equal(7.6, Qwen7B.ActiveBillions);
        Assert.False(Qwen3_4B.IsMixture); // "-instruct" isn't "-a4b"
    }

    [Fact]
    public void A_mixture_runs_from_memory_when_the_pc_has_room()
    {
        Assert.True(Qwen30A3.RunsFromMemory(6 * GB, 40 * GB));  // this PC: a 6 GB GPU and 40 GB of RAM
        Assert.True(Qwen30A3.RunsFromMemory(null, 32 * GB));
        Assert.False(Qwen30A3.RunsFromMemory(6 * GB, 16 * GB)); // too little RAM
        Assert.False(Qwen30A3.RunsFromMemory(6 * GB, null));    // RAM not known
        Assert.False(Qwen30A3.RunsFromMemory(24 * GB, 40 * GB)); // fits the GPU: runs there instead
        Assert.False(Big.RunsFromMemory(6 * GB, 64 * GB));      // an ordinary 14B on the processor is too slow
        Assert.False(new LocalModel("qwen3:235b-a22b", 235, 142 * GB, "qwen3moe").RunsFromMemory(6 * GB, 256 * GB)); // 22B at work
    }

    [Fact]
    public void With_enough_memory_the_mixture_is_the_best()
    {
        var installed = Installed.Append(Qwen30A3).ToArray();
        Assert.Equal(Qwen30A3, NotesModels.PickBest(installed, 6 * GB, 40 * GB));
        Assert.Equal(Qwen7B, NotesModels.PickBest(installed, 6 * GB, 16 * GB));
        Assert.Equal(Qwen7B, NotesModels.PickBest(installed, 6 * GB)); // RAM not known: as before
        Assert.True(NotesModels.Fits(Qwen30A3, 6 * GB, 40 * GB));
        Assert.False(NotesModels.Fits(Qwen30A3, 6 * GB, 16 * GB));
    }

    [Fact]
    public void A_model_too_big_for_the_gpu_is_held_in_ram()
    {
        var dense27 = new LocalModel("qwen3.8:27b-q4_K_M", 27.8, 17 * GB, "qwen35");
        Assert.True(dense27.HeldInRam(6 * GB));
        Assert.False(dense27.IsMixture);
        Assert.False(dense27.RunsFromMemory(6 * GB, 40 * GB)); // all of it works on each word: too slow to be the best
        Assert.Equal(Qwen7B, NotesModels.PickBest(Installed.Append(dense27), 6 * GB, 40 * GB));
        Assert.False(dense27.HeldInRam(24 * GB));
        Assert.True(Qwen30A3.HeldInRam(6 * GB));
        Assert.False(Qwen7B.HeldInRam(6 * GB));
        Assert.False(Qwen7B.HeldInRam(null)); // no GPU: only over 8 GB
        Assert.True(dense27.HeldInRam(null));
    }

    [Fact]
    public void Gpu_memory_reads_as_gigabytes() => Assert.Equal("6 GB", NotesModels.Gb(6 * GB));
}
