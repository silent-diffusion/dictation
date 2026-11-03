import AVFoundation
import Foundation
import Speech

/// Runs a kept dictation again from its recording (HistoryRerun.cs): transcribed afresh with today's speech settings
/// (language, vocabulary hint), then cleaned up again by the profile it was dictated with (or the active one, if that
/// profile is gone). The result replaces the entry's text; what it had before is kept as `earlier`, so it can be put
/// back. Nothing is inserted, and the dashboard counts and Analytics are left as they were (the dictation happened once).
public enum HistoryRerun {
    /// Run `entry` again. Returns the changed entry and a sentence saying what was done; throws `UserFacingError`.
    public static func run(_ entry: HistoryEntry, profiles: [Profile], active: Profile, settings: AppSettings,
                           progress: @MainActor (String) -> Void) async throws -> (HistoryEntry, String) {
        guard entry.hasAudio, let url = entry.audioURL else {
            throw UserFacingError("The recording of this dictation isn't kept any more, so it can't be run again.")
        }
        let found = profiles.first { $0.name.caseInsensitiveCompare(entry.profileName) == .orderedSame }
        let profileNote = found == nil ? " (the profile \"\(entry.profileName)\" is gone, so \(active.name) was used)" : ""
        let profile = found ?? active

        // 1. Speech: the speech model in Settings (Apple's on-device recognizer or Whisper), from the file.
        let heard: String
        if let whisper = settings.whisperModel {
            await progress("Transcribing again with \(WhisperModels.name(of: whisper))…")
            heard = try await WhisperAudio.rerun(url, model: whisper, language: settings.whisperLanguage,
                                                 vocabulary: settings.vocabularyHint, even: settings.evenOutVolume)
        } else {
            await progress("Transcribing again with on-device speech recognition…")
            heard = try await transcribe(url, locale: settings.speechLocale, vocabulary: settings.vocabulary)
        }
        try Task.checkCancellation()
        guard OutputSanitizer.hasContent(heard) else {
            throw UserFacingError("Nothing was heard in the recording this time; the dictation was left as it was.")
        }

        // 2. Cleanup by the profile, as a dictation does.
        var aiEdit: String?, warning: String?, final = heard, safetyNet = false
        if !profile.isRaw {
            await progress("Cleaning up with \(profile.name)…")
            let result = await TextProcessor(settings: settings).process(heard, profile: profile)
            final = result.text
            if result.modified { aiEdit = result.text }
            safetyNet = result.safetyNet
            warning = result.error.map { $0 + " The transcription was kept as heard." } ?? result.warning
        }
        try Task.checkCancellation()

        var changed = entry
        changed.earlier = entry.version
        changed.apply(HistoryVersion(transcription: heard, aiEdit: aiEdit, inserted: final.trimmingCharacters(in: .whitespacesAndNewlines),
                                     safetyNet: safetyNet, warning: warning, profileName: profile.name, wasInserted: false))
        changed.runAgainAt = Date()
        changed.showingEarlier = false
        let speech = settings.whisperModel.map(WhisperModels.name(of:)) ?? "on-device speech recognition"
        return (changed, "Run again with \(speech) and the \(profile.name) profile\(profileNote). Not inserted anywhere: copy it, or insert it below.")
    }

    /// Swap the entry's text with what it had before it was run again (so this undoes, and redoes, a rerun).
    public static func swapEarlier(_ entry: HistoryEntry) -> HistoryEntry {
        guard let e = entry.earlier else { return entry }
        var swapped = entry
        swapped.earlier = entry.version
        swapped.apply(e)
        swapped.showingEarlier = !(entry.showingEarlier ?? false)
        return swapped
    }

    /// The whole transcript of an audio file, from Apple's on-device recognizer.
    public static func transcribe(_ url: URL, locale: Locale, vocabulary: [String]) async throws -> String {
        let locale = try await LiveTranscriber.prepare(locale: locale)
        LiveTranscriber.markInUse()
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw UserFacingError("This recording can't be read, so it can't be run again.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let collect = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
            return text
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collect.cancel()
            throw error
        }
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
