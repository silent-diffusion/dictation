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

    [Fact]
    public void Gpu_memory_reads_as_gigabytes() => Assert.Equal("6 GB", NotesModels.Gb(6 * GB));
}
