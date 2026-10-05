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
/// A profile without AI goes further: the recognizer's running guess is typed as it is heard (about every second, the
/// same words the overlay shows), pasted (or typed, if the profile says so), and corrected in place with Backspace when
/// the guess changes.
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
    string _partialTyped = "";   // typed from the running guess, after _typed; revised as the guess changes
    string? _pendingPartial;     // the newest guess, not typed yet (older ones are skipped)
    bool _partialQueued;

    public LiveInsertion(TextInserter inserter, ITextProcessor llm, InsertionTarget target, Profile profile,
        Task<InsertionContext?> context)
    {
        _inserter = inserter; _llm = llm; _target = target; _profile = profile; _context = context;
    }

    /// <summary>Exactly what has been typed so far, in order.</summary>
    public string Typed => _typed + _partialTyped;
    public bool HasTyped => _typed.Length + _partialTyped.Length > 0;

    /// <summary>No AI: the words go in as they are heard, not only once a piece is finished.</summary>
    bool Streams => !_profile.AutoProcess;

    /// <summary>The recognizer's running guess at the speech since the last finished piece. Typed right away for a
    /// profile without AI; ignored otherwise (the AI needs finished sentences).</summary>
    public void SetPartial(string partial)
    {
        if (!Streams || _cts.IsCancellationRequested) return;
        _pendingPartial = partial;
        if (_partialQueued) return; // the queued update will pick up this newer guess
        _partialQueued = true;
        _queue = ApplyPartialAsync(_queue);
    }

    async Task ApplyPartialAsync(Task previous)
    {
        await previous;
        _partialQueued = false;
        var partial = _pendingPartial;
        _pendingPartial = null;
        try
        {
            if (partial == null || _cts.IsCancellationRequested || SpeechGuard.IsStockPhrase(partial)) return;
            // Never pull focus back mid-dictation; the finished piece or the final pass catches up.
            if (_held.Count > 0 || Native.GetForegroundWindow() != _target.Hwnd) return;
            await ReplacePartialAsync(await FitAsync(partial), _cts.Token);
        }
        catch (OperationCanceledException) { }
        catch (UserFacingException e) { Log.Warn("Live typing of the running guess failed: " + e.Message); }
        catch (Exception e) { Log.Error("Live guess failed", e); }
    }

    /// <summary>Spacing and capitals for text that follows what has been typed for good so far.</summary>
    async Task<string> FitAsync(string text) =>
        text.Trim().Length == 0 ? "" : ContextFit.Apply(text.Trim(), await ContextAfterTypedAsync());

    /// <summary>Make the typed guess read <paramref name="want"/>: keep the part that already matches, erase the rest
    /// with Backspace, type the difference.</summary>
    async Task ReplacePartialAsync(string want, CancellationToken ct)
    {
        var keep = 0;
        while (keep < _partialTyped.Length && keep < want.Length && _partialTyped[keep] == want[keep]) keep++;
        if (keep > 0 && keep < _partialTyped.Length && char.IsLowSurrogate(_partialTyped[keep])) keep--; // whole characters only
        if (keep < _partialTyped.Length)
        {
            await _inserter.EraseAsync(_partialTyped[keep..], _target, ct);
            _partialTyped = _partialTyped[..keep];
        }
        if (keep < want.Length)
        {
            if (_profile.LiveTyping) await _inserter.TypeAsync(want[keep..], _target, ct);
            else await _inserter.PasteAsync(want[keep..], _target, ct);
            _partialTyped = want;
        }
    }

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
                if (_partialTyped.Length > 0)
                {
                    // The piece's words are mostly typed already, as they were heard: correct them into the final piece.
                    await ReplacePartialAsync(text, _cts.Token);
                    _partialTyped = "";
                }
                else await _inserter.InsertAsync(text, _target, _cts.Token);
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

    /// <summary>The original context, with the finished pieces live dictation already typed appended to the text
    /// before the caret (not the running guess, which the next text replaces).</summary>
    async Task<InsertionContext?> ContextAfterTypedAsync()
    {
        var ctx = await _context;
        if (_typed.Length == 0) return ctx;
        return new InsertionContext((ctx?.Before ?? "") + _typed, ctx?.After ?? "");
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
        if (_partialTyped.Length > 0)
        {
            // The last words went in as they were heard: correct them into the rest rather than typing them twice.
            try { await ReplacePartialAsync(missing, ct); }
            catch (UserFacingException e) { Log.Warn("Couldn't correct the last words typed live: " + e.Message); }
            missing = "";
        }
        else if (missing.Length > 0) await _inserter.InsertAsync(missing, _target, ct);
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
