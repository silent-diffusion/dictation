using System.Text;
using Dictation.Core.Infrastructure;
using Dictation.Core.Insertion;
using Dictation.Core.Settings;
using Dictation.Core.Speech;
using Dictation.Core.Text;

namespace Dictation.Core.Session;

/// <summary>
/// "Type as you speak" for one dictation. While recording, each finished piece from the recognizer (whole
/// sentences, every ~5 s) is cleaned up and typed into the target right away. When the user stops, the whole
/// recording is transcribed and cleaned in one pass and replaces everything typed live; that replacement only
/// happens after confirming (via UI Automation) that the text before the caret is exactly what was typed.
/// With a profile that rewrites the whole dictation (an email, say), pieces are typed as spoken, since the
/// instructions only make sense for the whole, and the rewrite replaces them at the end.
/// Use from the UI thread only.
/// </summary>
public sealed class LiveInsertion
{
    static readonly TimeSpan UiaTimeout = TimeSpan.FromMilliseconds(700);

    readonly TextInserter _inserter;
    readonly ITextProcessor _llm;
    readonly InsertionTarget _target;
    readonly Profile _profile;
    readonly Task<InsertionContext?> _context;
    readonly CancellationTokenSource _cts = new();
    readonly StringBuilder _typed = new();
    readonly List<string> _held = new(); // cleaned pieces not typed: the target lost focus, or typing failed
    Task _queue = Task.CompletedTask;

    public LiveInsertion(TextInserter inserter, ITextProcessor llm, InsertionTarget target, Profile profile,
        Task<InsertionContext?> context)
    {
        _inserter = inserter; _llm = llm; _target = target; _profile = profile; _context = context;
    }

    /// <summary>Exactly what has been typed so far, in order.</summary>
    public string Typed => _typed.ToString();
    public bool HasTyped => _typed.Length > 0;

    /// <summary>Queue a finished piece; pieces are cleaned and typed strictly in order.</summary>
    public void Add(string piece) => _queue = AddAsync(_queue, piece);

    /// <summary>Wait until every queued piece is typed (or held).</summary>
    public Task DrainAsync() => _queue;

    /// <summary>Stop typing pieces (the dictation was cancelled or failed).</summary>
    public void Stop() => _cts.Cancel();

    async Task AddAsync(Task previous, string piece)
    {
        await previous;
        try
        {
            if (_cts.IsCancellationRequested || SpeechGuard.IsStockPhrase(piece)) return;
            var cleaned = await CleanAsync(piece, _cts.Token);
            if (_cts.IsCancellationRequested) return;
            // Never pull focus back mid-dictation; whatever can't be typed now is handled when the user stops.
            if (_held.Count > 0 || Native.GetForegroundWindow() != _target.Hwnd) { _held.Add(cleaned); return; }
            var text = ContextFit.Apply(cleaned, await ContextAfterTypedAsync());
            try
            {
                await _inserter.InsertAsync(text, _target, _cts.Token);
                _typed.Append(text);
            }
            catch (UserFacingException e)
            {
                Log.Warn("Live insertion failed: " + e.Message);
                _held.Add(cleaned);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { Log.Error("Live piece failed", e); }
    }

    async Task<string> CleanAsync(string raw, CancellationToken ct)
    {
        if (!_profile.AutoProcess || _profile.RewriteWhole || string.IsNullOrWhiteSpace(raw)) return raw.Trim();
        try { return (await _llm.ProcessAsync(raw, _profile, ct)).Text; }
        catch (UserFacingException e)
        {
            Log.Warn("Live cleanup failed; typing the raw words: " + e.Message);
            return raw.Trim();
        }
    }

    /// <summary>The original context, with what live dictation already typed appended to the text before the caret.</summary>
    async Task<InsertionContext?> ContextAfterTypedAsync()
    {
        var ctx = await _context;
        if (!HasTyped) return ctx;
        return new InsertionContext((ctx?.Before ?? "") + Typed, ctx?.After ?? "");
    }

    /// <summary>
    /// The user stopped. Replace the live text with <paramref name="finalText"/> (the whole recording, cleaned in one
    /// pass). If the live text can't be confirmed in place, keep it and type only what is missing: pieces that were
    /// held back and <paramref name="tailRaw"/>, the speech after the last piece.
    /// </summary>
    /// <returns>The text now in the document for this dictation, and a note when the final pass couldn't run.</returns>
    public async Task<(string Inserted, string? Note)> FinishAsync(string finalText, string tailRaw, CancellationToken ct)
    {
        await DrainAsync();
        if (!await _inserter.FocusAsync(_target, ct))
            throw new UserFacingException("Couldn't switch back to the app you were typing in. Click into it and try again.");

        var rewrite = _profile.RewriteWhole && _profile.AutoProcess;
        if (IsPlausibleReplacement(finalText, Typed, rewrite) && await InsertionContext.SelectBeforeCaretAsync(Typed, UiaTimeout))
        {
            var replacement = ContextFit.Fit(finalText, await _context, spacingOnly: rewrite);
            await _inserter.InsertAsync(replacement, _target, ct); // replaces the selection
            Log.Info($"Live dictation: final pass replaced {Typed.Length} typed chars with {replacement.Length}");
            return (replacement, null);
        }

        var rest = new List<string>(_held);
        if (!string.IsNullOrWhiteSpace(tailRaw)) rest.Add(await CleanAsync(tailRaw, ct));
        var missing = ContextFit.Apply(string.Join(" ", rest.Where(r => r.Length > 0)), await ContextAfterTypedAsync());
        if (missing.Length > 0) await _inserter.InsertAsync(missing, _target, ct);
        Log.Info("Live dictation: couldn't confirm the typed text, so the final pass was skipped");
        if (rewrite && !string.IsNullOrWhiteSpace(finalText))
        {
            // The words as spoken are in the document; hand over the rewrite so it isn't lost.
            try { System.Windows.Clipboard.SetText(finalText); } catch { }
            return (Typed + missing,
                "This app didn't let Oberton replace the text it typed while you spoke, so your words were kept as " +
                "spoken. The rewritten version is on your clipboard.");
        }
        return (Typed + missing,
            "This app didn't let Oberton confirm the text it typed while you spoke, so that text was kept as typed " +
            "and only the rest was added.");
    }

    /// <summary>The final pass must cover at least most of what was already typed: an empty or much shorter result
    /// (a failed final decode, a model that summarized) would delete the user's words. A rewrite (see
    /// <see cref="Profile.RewriteWhole"/>) may legitimately be much shorter; the AI step already checked it.</summary>
    public static bool IsPlausibleReplacement(string finalText, string typed, bool rewrite = false)
    {
        static int Words(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        return Words(finalText) > 0 && Words(finalText) >= Words(typed) * (rewrite ? 0.1 : 0.6);
    }

    /// <summary>Cancelled: remove what was typed live, if it can be confirmed in place.</summary>
    public async Task RemoveTypedAsync()
    {
        Stop();
        await DrainAsync();
        if (!HasTyped || !await _inserter.FocusAsync(_target)) return;
        if (await InsertionContext.SelectBeforeCaretAsync(Typed, UiaTimeout)) await _inserter.DeleteSelectionAsync();
        else Log.Info("Live dictation cancelled; the typed text couldn't be confirmed, so it was left in place");
    }
}
