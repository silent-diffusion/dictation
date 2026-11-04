import Combine
import Foundation
import ObertonCore

/// Settings › Model unloading (App.xaml.cs UnloadIdleModelsAsync / UnloadSoonIfImmediate): every 15 s, let the speech
/// model and the Read aloud voice go once they have been unused for `unloadAfterMinutes`. Ollama lets the AI model go
/// by itself, through the keep_alive sent with every request (`AppSettings.ollamaKeepAlive`). "Immediately after use"
/// frees everything 3 s after a dictation ends or the player closes. The speech model never goes while Extended Notes
/// needs it, and the voice never while the player shows, its DONE card included (Windows' ReaderWindow.IsBusy =
/// visible); `AppModel.unloadNow` checks both too. Each model loads again by itself the next time it's needed.
@MainActor
final class ModelUnloader {
    private weak var model: AppModel?
    private var timer: Timer?
    private var soon: Task<Void, Never>?
    private var watches: Set<AnyCancellable> = []

    func start(_ model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.unloadIdleModels() }
        }
        model.$phase.map(\.isBusy).removeDuplicates().dropFirst()
            .sink { [weak self] busy in if !busy { self?.unloadSoonIfImmediate() } }
            .store(in: &watches)
        // The player closed (✕, or by itself after the end): ReaderWindow.Stop starts the 3 s timer.
        model.reader.$isOpen.combineLatest(model.reader.$question.map { $0 != nil }).map { $0 || $1 }
            .removeDuplicates().dropFirst()
            .sink { [weak self] showing in
                if !showing { self?.unloadSoonIfImmediate() }
            }
            .store(in: &watches)
    }

    private func unloadIdleModels() async {
        guard let model else { return }
        let minutes = model.settings.unloadAfterMinutes
        guard minutes > 0 else { return }
        let idle = TimeInterval(minutes * 60)
        // Extended Notes holds only the speech model; an idle voice still goes (App.UnloadIdleModelsAsync).
        // Each unload logs itself ("Speech model unloaded after being idle", as Windows' engines do).
        if !model.notes.needsModels, !model.phase.isBusy, model.speechLoaded, Date.now.timeIntervalSince(model.lastActivity) > idle {
            _ = await model.unloadNow(speech: true, ai: false, voice: false)
        }
        // The voice counts from the last sentence it was asked to speak (Windows' `Tts.LastUsed`).
        if !model.reader.isShowing, model.reader.isLoaded, Date.now.timeIntervalSince(SpeechVoices.shared.lastUsed) > idle {
            _ = await model.unloadNow(speech: false, ai: false, voice: true)
        }
    }

    /// "Immediately after use": a few seconds after a dictation or a reading ends, free every model that isn't in use.
    /// The short wait lets a reading that follows a dictation start first, and keeps a quick second dictation from
    /// reloading everything.
    private func unloadSoonIfImmediate() {
        guard let model, model.settings.unloadAfterMinutes == AppSettings.unloadImmediately, !model.notes.needsModels else { return }
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let model = self?.model, !model.phase.isBusy, !model.reader.isShowing else { return }
            Log.info("Unload immediately: " + (await model.unloadNow(speech: true, ai: true, voice: true)))
        }
    }
}

extension AppModel {
    /// When the speech model unloads by itself, or nil: unloading right after use, never unloading, or nothing loaded. For the dashboard's unload note and speech dial (counted from the last dictation, as on Windows).
    var unloadAt: Date? {
        let minutes = settings.unloadAfterMinutes
        guard minutes > 0, speechLoaded else { return nil }
        return lastActivity.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// The time left until `unloadAt`, from now (0 once it is due).
    var unloadCountdown: TimeInterval? { unloadAt.map { max(0, $0.timeIntervalSinceNow) } }

    /// The dashboard's unload line (DashboardPage.xaml.cs): "Models unload right after use", "Models stay loaded",
    /// "Nothing loaded" or "Unload in 12:34". Read it inside a 1 s TimelineView for a running clock.
    var unloadNote: String {
        let minutes = settings.unloadAfterMinutes
        if minutes < 0 { return "Models unload right after use" }
        if minutes == 0 { return "Models stay loaded" }
        guard let left = unloadCountdown else { return "Nothing loaded" }
        let s = Int(left)
        return String(format: "Unload in %02d:%02d", s / 60, s % 60)
    }
}
