import ObertonCore
import SwiftUI

/// A profile page's Try it waiting for a choice in the dictation preview (Windows' OverlayWindow.PreviewTrialAsync,
/// with "Preview before inserting" on): the same ✓ READY TO INSERT card a dictation gets, in the overlay at the user's
/// overlay position, chip "Try it · {profile}", INSERT, USE ORIGINAL and DISCARD. Nothing is inserted anywhere.
///
/// It belongs to the app, not to the page: opening another profile meanwhile leaves the preview up, and the choice
/// still goes back to the run that asked for it (which then reads it aloud if its profile says so), as on Windows. A
/// new Try it replaces it (the old one counts as discarded), and so does a real dictation (`AppModel.phase`).
struct TrialPreview: Identifiable {
    let id = UUID()
    /// What the preview shows: the sample as heard, and the edit as what goes in.
    let entry: HistoryEntry
    let profileName: String
    /// The profile uses AI (Windows' usesAi = AutoProcess): the AI EDIT box shows the edit, else "No AI edit".
    let usesAI: Bool

    /// The chip: "Try it · Email Formatter".
    var chip: String { "Try it · " + profileName }
}

extension AppModel {
    /// The one Try it waiting for its choice (Windows' `_trial`).
    private static let trials = ChoiceSlot<TrialPreview, String>()

    /// Show Try it's result in the overlay's preview and wait for the choice: the text that would go in (the edit, or
    /// the original with USE ORIGINAL), or nil when discarded. `model` names the AI model for the preview (nil: none).
    func previewTrial(profileName: String, raw: String, edited: String, usesAI: Bool, model: String?) async -> String? {
        let entry = HistoryEntry(transcription: raw, aiEdit: usesAI ? edited : nil, inserted: edited, profileName: profileName,
                                 model: model, appName: nil, seconds: 0, turnaroundSeconds: 0, warning: nil, safetyNet: false,
                                 wasInserted: false)
        return await Self.trials.ask(TrialPreview(entry: entry, profileName: profileName, usesAI: usesAI)) { [weak self] shown in
            self?.trialPreview = shown
        }
    }

    /// The preview's buttons (Windows' EndTrial): INSERT gives the edit, USE ORIGINAL the sample, DISCARD nil.
    func endTrial(_ result: String?) { Self.trials.end(result) }
}

/// The overlay's card for a waiting Try it.
struct TrialPreviewPill: View {
    let trial: TrialPreview
    var opacity: Double
    @EnvironmentObject var model: AppModel

    var body: some View {
        // No hotkey on INSERT (Windows sets "INSERT"), and no text around a cursor: nothing is being inserted.
        PreviewPill(entry: trial.entry, profile: trial.chip, hotkey: "", opacity: opacity, context: nil, usesAI: trial.usesAI,
                    onInsert: { model.endTrial(trial.entry.inserted) },
                    onOriginal: { model.endTrial(trial.entry.transcription) },
                    onDiscard: { model.endTrial(nil) })
    }
}
