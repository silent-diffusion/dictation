using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Dictation.Core.Infrastructure;

namespace Dictation.Core.Speech;

/// <summary>
/// A second, independent connection to the running speech engine (inference/asr_server.py), for Extended Notes. The
/// server gives every connection its own session and shares the loaded model between them (one decode at a time), so a
/// long notes session and a dictation never get in each other's way and no second model is loaded. Live mode: finished
/// pieces arrive as <see cref="Committed"/> every few seconds.
/// </summary>
public sealed class SpeechSessionClient : IAsyncDisposable
{
    readonly ClientWebSocket _ws = new();
    readonly Channel<(bool Binary, byte[] Data)> _outbox = Channel.CreateUnbounded<(bool, byte[])>(new UnboundedChannelOptions { SingleReader = true });
    readonly CancellationTokenSource _life = new();
    readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    TaskCompletionSource<string>? _final;
    volatile bool _connected;

    /// <summary>A finished piece of text (background thread).</summary>
    public event Action<string>? Committed;
    /// <summary>The connection dropped (the engine stopped or restarted); background thread.</summary>
    public event Action? Disconnected;

    public bool IsConnected => _connected && _ws.State == WebSocketState.Open;

    public async Task ConnectAsync(int port, CancellationToken ct)
    {
        await _ws.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/"), ct);
        _connected = true;
        _ = Task.Run(ReceiveLoop);
        _ = Task.Run(SendLoop);
        await _ready.Task.WaitAsync(TimeSpan.FromSeconds(10), ct);
    }

    /// <summary>Begin a live session (finished pieces every few seconds).</summary>
    public void Start(string? language, string? prompt)
    {
        var msg = JsonSerializer.Serialize(new { type = "start", language, prompt, live = true });
        _outbox.Writer.TryWrite((false, Encoding.UTF8.GetBytes(msg)));
    }

    public void Send(byte[] pcm16kMono) { if (_connected) _outbox.Writer.TryWrite((true, pcm16kMono)); }

    /// <summary>Finish: decodes the speech after the last piece and returns that text (the tail).</summary>
    public async Task<string> StopAsync(TimeSpan timeout)
    {
        var tcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        _final = tcs;
        _outbox.Writer.TryWrite((false, Encoding.UTF8.GetBytes("{\"type\":\"stop\"}")));
        try { return await tcs.Task.WaitAsync(timeout); }
        catch (TimeoutException) { Log.Warn("Extended notes: the speech engine didn't finish the last piece in time"); return ""; }
    }

    async Task SendLoop()
    {
        try
        {
            await foreach (var (binary, data) in _outbox.Reader.ReadAllAsync(_life.Token))
                await _ws.SendAsync(data, binary ? WebSocketMessageType.Binary : WebSocketMessageType.Text, true, _life.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Lost("send: " + e.Message); }
    }

    async Task ReceiveLoop()
    {
        var buf = new byte[64 * 1024];
        try
        {
            while (!_life.IsCancellationRequested && _ws.State == WebSocketState.Open)
            {
                using var ms = new MemoryStream();
                WebSocketReceiveResult r;
                do
                {
                    r = await _ws.ReceiveAsync(buf, _life.Token);
                    if (r.MessageType == WebSocketMessageType.Close) throw new WebSocketException("closed");
                    ms.Write(buf, 0, r.Count);
                } while (!r.EndOfMessage);
                Handle(Encoding.UTF8.GetString(ms.ToArray()));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Lost("receive: " + e.Message); }
    }

    void Handle(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        switch (root.GetProperty("type").GetString())
        {
            case "ready": _ready.TrySetResult(); break;
            case "commit":
                var text = root.GetProperty("text").GetString() ?? "";
                if (text.Trim().Length > 0) Committed?.Invoke(text);
                break;
            case "final":
                _final?.TrySetResult(root.TryGetProperty("tail", out var tail) ? tail.GetString() ?? "" : "");
                break;
            case "error":
                Log.Warn("Extended notes speech: " + root.GetProperty("message").GetString());
                break;
        }
    }

    void Lost(string why)
    {
        if (_life.IsCancellationRequested || !_connected) return;
        _connected = false;
        Log.Warn("Extended notes lost the speech engine (" + why + ")");
        _final?.TrySetResult("");
        Disconnected?.Invoke();
    }

    public async ValueTask DisposeAsync()
    {
        _connected = false;
        _life.Cancel();
        try { if (_ws.State == WebSocketState.Open) await _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2)); }
        catch { }
        _ws.Dispose();
    }
}
