using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Dictation.Core.Infrastructure;
using Dictation.Core.Settings;

namespace Dictation.Core.Text;

/// <summary>A cloud model a profile can use instead of a local one.</summary>
/// <param name="Id">What is stored in a profile's Model field: "provider:model".</param>
public sealed record CloudModel(string Id, string Provider, string Name, string Description);

/// <summary>
/// Optional cloud models (Anthropic, or OpenAI and compatible services). A profile selects one by setting its model to
/// "anthropic:…" or "openai:…". Nothing is sent while <see cref="CloudSettings.KeepOffline"/> is on, which is the default.
/// </summary>
public static class CloudModels
{
    public const string Anthropic = "anthropic", OpenAi = "openai";

    public static bool IsCloud(string? model) =>
        model != null && (model.StartsWith(Anthropic + ":", StringComparison.OrdinalIgnoreCase) ||
                          model.StartsWith(OpenAi + ":", StringComparison.OrdinalIgnoreCase));

    public static (string Provider, string Name) Split(string model)
    {
        var i = model.IndexOf(':');
        return (model[..i].ToLowerInvariant(), model[(i + 1)..]);
    }

    /// <summary>The cloud models to offer: Anthropic's current ones, and the configured OpenAI-compatible model.</summary>
    public static IReadOnlyList<CloudModel> Catalog(CloudSettings s) => new[]
    {
        new CloudModel(Anthropic + ":claude-haiku-4-5-20251001", "Anthropic", "Claude Haiku 4.5", "Fast and inexpensive; plenty for cleanup."),
        new CloudModel(Anthropic + ":claude-sonnet-5-5", "Anthropic", "Claude Sonnet 5.5", "Stronger rewriting, e.g. emails from rambling."),
        new CloudModel(Anthropic + ":claude-opus-5-5", "Anthropic", "Claude Opus 5.5", "The most capable; slower and pricier."),
        new CloudModel(OpenAi + ":" + s.OpenAiModel, "OpenAI-compatible", s.OpenAiModel, "From " + s.OpenAiBaseUrl),
    };

    public static bool HasKey(CloudSettings s, string provider) =>
        !string.IsNullOrEmpty(provider == Anthropic ? s.AnthropicKey : s.OpenAiKey);
}

/// <summary>API keys are encrypted with Windows DPAPI for the current user, so the settings file alone is useless.</summary>
public static class SecretStore
{
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Oberton.CloudKey.v1");

    public static string? Protect(string? secret)
    {
        if (string.IsNullOrWhiteSpace(secret)) return null;
        var data = ProtectedData.Protect(Encoding.UTF8.GetBytes(secret.Trim()), Entropy, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(data);
    }

    public static string? Unprotect(string? stored)
    {
        if (string.IsNullOrEmpty(stored)) return null;
        try
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(stored), Entropy, DataProtectionScope.CurrentUser));
        }
        catch (Exception e)
        {
            Log.Warn("A stored API key could not be decrypted (another Windows user or PC?): " + e.GetType().Name);
            return null;
        }
    }
}

/// <summary>One chat completion against a cloud provider, in the same shape the local model gets.</summary>
public sealed class CloudCompletion
{
    readonly SettingsService _settings;
    readonly HttpClient _http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public CloudCompletion(SettingsService settings) => _settings = settings;

    /// <param name="examples">Before/after pairs sent as earlier turns of the conversation.</param>
    public async Task<string> CompleteAsync(string model, string system, IReadOnlyList<(string In, string Out)> examples,
        string user, int maxTokens, CancellationToken ct)
    {
        var cloud = _settings.Current.Cloud;
        if (cloud.KeepOffline)
            throw new UserFacingException("This profile uses a cloud model, but \"Keep everything offline\" is on. " +
                                          "Turn it off under Settings › Cloud AI, or pick a local model.");
        var (provider, name) = CloudModels.Split(model);
        var key = SecretStore.Unprotect(provider == CloudModels.Anthropic ? cloud.AnthropicKey : cloud.OpenAiKey);
        if (string.IsNullOrEmpty(key))
            throw new UserFacingException($"No API key is set for {(provider == CloudModels.Anthropic ? "Anthropic" : "OpenAI")}. " +
                                          "Add one under Settings › Cloud AI.");

        var turns = new JsonArray();
        foreach (var (i, o) in examples)
        {
            turns.Add(new JsonObject { ["role"] = "user", ["content"] = i });
            turns.Add(new JsonObject { ["role"] = "assistant", ["content"] = o });
        }
        turns.Add(new JsonObject { ["role"] = "user", ["content"] = user });

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(Math.Max(10, _settings.Current.Llm.TimeoutSeconds)));
        try
        {
            return provider == CloudModels.Anthropic
                ? await AnthropicAsync(key, name, system, turns, maxTokens, cts.Token)
                : await OpenAiAsync(key, cloud.OpenAiBaseUrl, name, system, turns, maxTokens, cts.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new UserFacingException("The cloud model took too long to respond.");
        }
        catch (HttpRequestException e)
        {
            throw new UserFacingException("Couldn't reach the cloud AI service. Check your internet connection.", e);
        }
    }

    async Task<string> AnthropicAsync(string key, string model, string system, JsonArray turns, int maxTokens, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages")
        {
            Content = JsonContent.Create(new JsonObject
            {
                ["model"] = model,
                ["max_tokens"] = maxTokens,
                ["temperature"] = 0,
                ["system"] = system,
                ["messages"] = turns,
            }),
        };
        req.Headers.Add("x-api-key", key);
        req.Headers.Add("anthropic-version", "2023-06-01");
        var json = await SendAsync(req, "Anthropic", ct);
        var sb = new StringBuilder();
        foreach (var block in json["content"]?.AsArray() ?? new JsonArray())
            if (block?["type"]?.GetValue<string>() == "text") sb.Append(block["text"]?.GetValue<string>());
        return sb.ToString();
    }

    async Task<string> OpenAiAsync(string key, string baseUrl, string model, string system, JsonArray turns, int maxTokens, CancellationToken ct)
    {
        var messages = new JsonArray { new JsonObject { ["role"] = "system", ["content"] = system } };
        foreach (var t in turns) messages.Add(t!.DeepClone());
        using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl.TrimEnd('/') + "/chat/completions")
        {
            // No temperature: some newer models only accept the default. OpenAI itself wants max_completion_tokens;
            // compatible services still use max_tokens.
            Content = JsonContent.Create(new JsonObject
            {
                ["model"] = model,
                ["messages"] = messages,
                [baseUrl.Contains("api.openai.com", StringComparison.OrdinalIgnoreCase) ? "max_completion_tokens" : "max_tokens"] = maxTokens,
            }),
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        var json = await SendAsync(req, "OpenAI", ct);
        return json["choices"]?[0]?["message"]?["content"]?.GetValue<string>() ?? "";
    }

    async Task<JsonObject> SendAsync(HttpRequestMessage req, string provider, CancellationToken ct)
    {
        using var resp = await _http.SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
        {
            string detail;
            try { detail = JsonNode.Parse(body)?["error"]?["message"]?.GetValue<string>() ?? body; }
            catch { detail = body; }
            if (detail.Length > 200) detail = detail[..200] + "…";
            Log.Warn($"{provider} returned {(int)resp.StatusCode}: {detail}");
            throw new UserFacingException(resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                ? $"{provider} rejected the API key. Check it under Settings › Cloud AI."
                : $"{provider} returned an error: {detail}");
        }
        return JsonNode.Parse(body)?.AsObject() ?? throw new UserFacingException($"{provider} sent an empty reply.");
    }
}
