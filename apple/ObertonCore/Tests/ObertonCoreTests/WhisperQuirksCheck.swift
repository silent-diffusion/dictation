import Foundation
import Testing
@testable import ObertonCore

/// End-to-end check of Whisper's quirks (repeated words, invented words, "Thank you." on silence) on real recordings,
/// through the three ways Oberton uses Whisper: a dictation (the debug fake-audio hook, in real time), Extended Notes'
/// live stream (fed in real time), and a whole file (History's Run again, Extended Notes' transcribe again).
/// Only when asked:
/// `OBERTON_WHISPER_QUIRKS=<folder of .wav> OBERTON_QUIRKS_OUT=<file.jsonl> OBERTON_WHISPER_MODELS=base.en,distil-large-v3
///  OBERTON_DATA_DIR=<scratch> swift test --filter WhisperQuirksCheck`
@Suite(.serialized) struct WhisperQuirksCheck {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_WHISPER_QUIRKS"] != nil))
    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: env["OBERTON_WHISPER_QUIRKS"]!)
        let out = URL(fileURLWithPath: env["OBERTON_QUIRKS_OUT"] ?? folder.appending(path: "results.jsonl").path)
        let label = env["OBERTON_QUIRKS_LABEL"] ?? "run"
        let paths = Set((env["OBERTON_QUIRKS_PATHS"] ?? "dictation,notes,file").split(separator: ",").map(String.init))
        let only = env["OBERTON_QUIRKS_CLIPS"].map { Set($0.split(separator: ",").map(String.init)) }
        let clips = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" && (only?.contains($0.deletingPathExtension().lastPathComponent) ?? true) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        func write(_ row: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                handle.write(data + Data("\n".utf8))
                print("QUIRKS " + String(decoding: data, as: UTF8.self))
            }
        }

        for model in (env["OBERTON_WHISPER_MODELS"] ?? "base.en").split(separator: ",").map(String.init) {
            if !WhisperModels.isDownloaded(model) { try await WhisperModels.download(model) { _ in } }
            try await WhisperEngine.shared.load(model)
            var settings = AppSettings()
            settings.speechModel = model
            for clip in clips {
                let name = clip.deletingPathExtension().lastPathComponent
                let samples = try WhisperAudio.samples(clip)
                let seconds = Double(samples.count) / 16_000
                var row: [String: Any] = ["label": label, "model": model, "clip": name]

                if paths.contains("dictation") {
                    // As AppModel.start/stop do it.
                    let t = LiveTranscriber()
                    var partials: [String] = []
                    t.onText = { partials.append($0) }
                    LiveTranscriber.fakeAudio = clip
                    try t.startRecording(microphone: nil, evenOut: settings.evenOutVolume)
                    try await t.startWhisper(model: model, language: settings.whisperLanguage, prompt: settings.vocabularyHint)
                    try await Task.sleep(for: .seconds(seconds + 0.3))
                    t.stopRecording()
                    let peak = t.peak
                    let started = Date()
                    let raw = NotesFormat.collapseRepeats(OutputSanitizer.collapseDots(await t.stop()))
                    LiveTranscriber.fakeAudio = nil
                    let discard = SpeechGuard.shouldDiscard(raw, recorded: seconds, peakLevel: peak)
                    row["dictation"] = discard ? "" : raw
                    row["dictation_raw"] = raw
                    row["dictation_ms"] = Int(Date().timeIntervalSince(started) * 1000)
                    row["partials"] = Array(Set(partials.filter { !$0.isEmpty })).sorted()
                }

                if paths.contains("notes") {
                    // As NotesRecorder.connectWhisper / stop do it: audio fed as it is recorded.
                    let pieces = PieceBox()
                    let stream = WhisperLiveStream(model: model, language: settings.whisperLanguage, vocabulary: settings.vocabularyHint,
                                                   even: settings.evenOutVolume) { text, at in
                        pieces.add(text, at)
                    }
                    stream.start()
                    let chunk = 4_000
                    var from = 0
                    while from < samples.count {
                        let to = min(samples.count, from + chunk)
                        stream.append(Array(samples[from..<to]))
                        from = to
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    if let (text, at) = await stream.finish() { pieces.add(text, at) }
                    row["notes"] = pieces.all.map(\.text).joined(separator: " ")
                    row["notes_pieces"] = pieces.all.map { "\(String(format: "%.1f", $0.at)): \($0.text)" }
                }

                if paths.contains("file") {
                    row["file"] = try await WhisperFileCheck.transcribe(clip, settings: settings)
                    if let redo = try await WhisperFileCheck.redo(clip, settings: settings) { row["redo"] = redo }
                }
                write(row)
            }
        }
    }
}

final class PieceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(text: String, at: Double)] = []
    func add(_ text: String, _ at: Double) { lock.withLock { items.append((text, at)) } }
    var all: [(text: String, at: Double)] { lock.withLock { items } }
}

/// What the speech detection makes of each recording: voiced seconds (as recorded and evened out) and the regions kept.
/// `OBERTON_WHISPER_PREP=<folder of .wav> swift test --filter WhisperPrepCheck`
@Suite struct WhisperPrepCheck {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_WHISPER_PREP"] != nil))
    func report() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBERTON_WHISPER_PREP"]!)
        for clip in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "wav" }).sorted(by: { $0.path < $1.path }) {
            let a = try WhisperAudio.samples(clip)
            let even = WhisperPrep.evened(a), voice = WhisperPrep.voiceOnly(a)
            func secs(_ p: WhisperPrep.Prepared?) -> String { p.map { String(format: "%.1f s in %d", Double($0.audio.count) / 16_000, $0.regions.count) } ?? "nothing" }
            print(String(format: "PREP %@: %.1f s, voiced %.2f s raw / %.2f s levelled; evened: %@; voice only: %@",
                         clip.deletingPathExtension().lastPathComponent, Double(a.count) / 16_000,
                         WhisperPrep.voicedSeconds(a), WhisperPrep.voicedSeconds(WhisperPrep.level(a)), secs(even), secs(voice)))
        }
    }
}

/// Whisper's segments for each recording, with what it reported about them (debugging the rules above).
/// `OBERTON_WHISPER_SEGMENTS=<folder of .wav> OBERTON_WHISPER_MODELS=… OBERTON_DATA_DIR=<scratch> swift test --filter WhisperSegmentsCheck`
@Suite struct WhisperSegmentsCheck {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_WHISPER_SEGMENTS"] != nil))
    func report() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: env["OBERTON_WHISPER_SEGMENTS"]!)
        let only = env["OBERTON_QUIRKS_CLIPS"].map { Set($0.split(separator: ",").map(String.init)) }
        for model in (env["OBERTON_WHISPER_MODELS"] ?? "base.en").split(separator: ",").map(String.init) {
            for clip in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "wav" && (only?.contains($0.deletingPathExtension().lastPathComponent) ?? true) }).sorted(by: { $0.path < $1.path }) {
                let samples = try WhisperAudio.samples(clip)
                // OBERTON_SEGMENTS_RAW: what Whisper makes of the recording as it is, without the speech detection.
                let raw = env["OBERTON_SEGMENTS_RAW"] != nil
                guard let audio = raw ? samples : WhisperPrep.evened(samples)?.audio else { print("SEG \(model) \(clip.lastPathComponent): nothing said"); continue }
                for s in try await WhisperEngine.shared.decode(audio, model: model, language: "en", prompt: "", step: 0.2) {
                    print(String(format: "SEG %@ %@: %.2f–%.2f nospeech %.2f logprob %.2f ratio %.2f phantom %@ | %@", model, clip.lastPathComponent,
                                 s.start, s.end, s.noSpeechProb, s.avgLogprob, s.compressionRatio, WhisperText.isPhantom(s) ? "yes" : "no", s.text))
                }
            }
        }
    }
}
