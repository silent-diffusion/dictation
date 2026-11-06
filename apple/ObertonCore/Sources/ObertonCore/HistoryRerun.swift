import AVFoundation
import Foundation
import Speech

/// Runs a kept dictation again from its recording (HistoryRerun.cs): transcribed afresh with today's speech settings
/// (language, vocabulary hint), then cleaned up again by the profile it was dictated with (or the active one, if that
/// profile is gone). The result replaces the entry's text; what it had before is kept as `earlier`, so it can be put
/// back. Nothing is inserted, and the dashboard counts and Analytics are left as they were (the dictation happened once).
public enum HistoryRerun {
    /// Run `entry` again. Returns the changed entry and a sentence saying what was done; throws `UserFacingError`.
    /// `canSwapSpeechModel`: false while something else relies on the speech model loaded now (an Extended Notes
    /// session); the rerun then uses that model instead of the profile's.
    public static func run(_ entry: HistoryEntry, profiles: [Profile], active: Profile, settings: AppSettings,
                           canSwapSpeechModel: Bool = true,
                           progress: @MainActor (String) -> Void) async throws -> (HistoryEntry, String) {
        guard entry.hasAudio, let url = entry.audioURL else {
            throw UserFacingError("The recording of this dictation isn't kept any more, so it can't be run again.")
        }
        let found = profiles.first { $0.name.caseInsensitiveCompare(entry.profileName) == .orderedSame }
        let profileNote = found == nil ? " (the profile \"\(entry.profileName)\" is gone, so \(active.name) was used)" : ""
        let profile = found ?? active

        // 1. Speech: the profile's speech model (Apple's on-device recognizer or Whisper), unless another one must stay
        // loaded; loaded first when it isn't in yet.
        var whisper = settings.whisperModel
        if let wanted = whisper, let loaded = WhisperEngine.loadedModel, loaded != wanted, !canSwapSpeechModel { whisper = loaded }
        let heard: String
        if let whisper {
            if WhisperEngine.loadedModel?.caseInsensitiveCompare(whisper) != .orderedSame {
                await progress("Loading \(WhisperModels.name(of: whisper))…")
                try await WhisperEngine.shared.load(whisper)
            }
            await progress("Transcribing again with \(WhisperModels.name(of: whisper))…")
            // As Windows, the file is checked once the model is in and transcribing begins.
            try checkFormat(url)
            heard = try await WhisperAudio.rerun(url, model: whisper, language: settings.whisperLanguage,
                                                 vocabulary: settings.vocabularyHint, even: settings.evenOutVolume)
        } else {
            await progress("Transcribing again with on-device speech recognition…")
            try checkFormat(url)
            heard = try await transcribe(url, locale: settings.speechLocale, vocabulary: settings.vocabulary, even: settings.evenOutVolume)
        }
        try Task.checkCancellation()
        guard OutputSanitizer.hasContent(heard) else {
            throw UserFacingError("Nothing was heard in the recording this time; the dictation was left as it was.")
        }

        // 2. Cleanup by the profile, as a dictation does (but no surrounding text to fit: that moment is gone).
        let raw = FragmentStitcher.tidy(heard)
        var aiEdit: String?, warning: String?, final = raw, safetyNet = false
        if !profile.isRaw {
            await progress("Cleaning up with \(profile.name)…")
            // As Windows: an AI error put into words for the user keeps the transcription as heard, with that note;
            // anything else ends the rerun with nothing changed ("See the log for details").
            let processor = TextProcessor(settings: settings)
            let model = processor.model(for: profile)
            do {
                let result = try await processor.edit(raw.trimmingCharacters(in: .whitespacesAndNewlines), profile: profile, backend: try await processor.backend(for: model, ask: false),
                                                      cloud: model.isCloud, model: model.windowsForm)
                final = result.text
                if result.modified { aiEdit = result.text }
                if result.safetyNet { safetyNet = true; warning = result.warning }
            } catch let e as UserFacingError where !Task.isCancelled {
                CoreLog.warn("History: the AI step of running a dictation again failed: " + e.message)
                warning = e.message + " The transcription was kept as heard."
            }
        }
        try Task.checkCancellation()

        var changed = entry
        changed.earlier = entry.version
        changed.apply(HistoryVersion(transcription: raw, aiEdit: aiEdit, inserted: final.trimmingCharacters(in: .whitespacesAndNewlines),
                                     safetyNet: safetyNet, warning: warning, profileName: profile.name, wasInserted: false))
        changed.runAgainAt = Date()
        changed.showingEarlier = false
        let speech = whisper.map(WhisperModels.name(of:)) ?? "on-device speech recognition"
        CoreLog.info("History: ran \(DateText.format(entry.date, "yyyyMMdd-HHmmss", Locale(identifier: "en_US_POSIX"))) again (\(speech), \(profile.name)): "
                     + "\(entry.transcription.utf16.count)->\(raw.utf16.count) chars heard")
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

    /// History keeps its recordings as 16 kHz mono 16-bit PCM; anything else isn't one of them.
    static func checkFormat(_ url: URL) throws {
        let format = try AVAudioFile(forReading: url).fileFormat
        let bits = (format.settings[AVLinearPCMBitDepthKey] as? Int) ?? 0
        let float = (format.settings[AVLinearPCMIsFloatKey] as? Bool) ?? false
        guard format.sampleRate == 16000, format.channelCount == 1, bits == 16, !float else {
            throw UserFacingError("This recording isn't in the format Oberton records in, so it can't be run again.")
        }
    }

    /// The whole transcript of an audio file, from Apple's on-device recognizer; with `even`, quiet speech is evened
    /// out first, as a dictation's is.
    public static func transcribe(_ url: URL, locale: Locale, vocabulary: [String], even: Bool = false) async throws -> String {
        let locale = try await LiveTranscriber.prepare(locale: locale)
        LiveTranscriber.markInUse()
        var levelled: URL?
        defer { if let levelled { try? FileManager.default.removeItem(at: levelled) } }
        if even {
            levelled = try evenedOut(url)
        }
        let file = try AVAudioFile(forReading: levelled ?? url)
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

    /// A copy of a recording with quiet speech evened out (VolumeLeveller), as 16 kHz mono 16-bit PCM in a temporary file.
    static func evenedOut(_ url: URL) throws -> URL {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return url }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return url }
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        VolumeLeveller(sampleRate: file.processingFormat.sampleRate).process(&samples)
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            withUnsafeBytes(of: Int16(max(-1, min(1, s)) * 32767).littleEndian) { pcm.append(contentsOf: $0) }
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "oberton-rerun-\(UUID().uuidString).wav")
        try WavFile.data(pcm: pcm, sampleRate: Int(file.processingFormat.sampleRate)).write(to: out, options: .atomic)
        return out
    }
}
