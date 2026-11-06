#if os(macOS) && DEBUG
import AVFoundation
import Foundation
import ObertonCore
import Speech

/// Debug only: checks the word times playback highlighting uses, end to end. A WAV made with `say` is played in place
/// of the microphone for a dictation (History keeps its words.json), then transcribed as Extended Notes would (Whisper's
/// live stream and Transcribe again, or Apple's recognizer on the file). Logs how many words came with times, whether
/// they run in order inside the recording, and how many words of each text line up with them. Then quits.
/// `OBERTON_WORDS_CHECK=apple` (Apple Speech) or `=base.en` (a downloaded Whisper model), `OBERTON_DATA_DIR=<scratch>`.
@MainActor
enum WordsCheck {
    static let sentence = "The quick brown fox jumps over the lazy dog. Oberton writes down what you say, on this Mac. " +
        "Whisper hears each sentence, and the notes keep them in order. This is the end of the test."

    static func run(_ model: AppModel, engine: String) {
        Task { @MainActor in
            let wav = FileManager.default.temporaryDirectory.appending(path: "words-check.wav")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", sentence]
            do { try say.run(); say.waitUntilExit() } catch { Log.error("WordsCheck: say failed: \(error)"); exit(1) }
            let seconds = (try? WhisperAudio.samples(wav).count).map { Double($0) / 16_000 } ?? 10

            let whisper = engine == "apple" ? nil : engine
            model.useSpeechModel(whisper ?? "")
            model.settings.keepHistory = true
            model.settings.saveHistoryAudio = true
            for _ in 0..<600 where !model.speechOK { try? await Task.sleep(for: .milliseconds(200)) }

            // A dictation, the WAV in place of the microphone.
            LiveTranscriber.fakeAudio = wav
            model.start()
            try? await Task.sleep(for: .seconds(seconds + 0.7))
            model.stop()
            for _ in 0..<600 where model.phase.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            LiveTranscriber.fakeAudio = nil
            if let e = model.lastEntry {
                report("dictation (History words.json)", e.spokenWords, seconds: seconds, texts: ["transcription": e.transcription, "inserted": e.inserted])
            } else {
                Log.error("WordsCheck: the dictation kept no History entry")
            }

            // Extended Notes' engines on the same audio.
            let samples = (try? WhisperAudio.samples(wav)) ?? []
            if let whisper {
                let stream = WhisperLiveStream(model: whisper, language: model.settings.whisperLanguage, vocabulary: "Oberton") { _, _ in }
                stream.start()
                var words: [SpokenWord] = []
                var text = ""
                for from in stride(from: 0, to: samples.count, by: 4_000) {
                    stream.append(Array(samples[from..<min(samples.count, from + 4_000)]))
                    try? await Task.sleep(for: .milliseconds(250))
                    words += stream.takeWords()
                }
                if let last = await stream.finish() { text = last.text }
                words += stream.takeWords()
                report("notes live stream", words, seconds: seconds, texts: ["end": text, "sentence": sentence])
                if let again = try? await WhisperAudio.redoTimed(wav, model: whisper, language: model.settings.whisperLanguage, vocabulary: "Oberton", even: true) {
                    report("notes transcribe again", again.words, seconds: seconds, texts: ["transcript": again.pieces.map(\.text).joined(separator: " ")])
                }
            } else {
                do {
                    let locale = try await LiveTranscriber.prepare(locale: model.settings.speechLocale)
                    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    let collect = Task { () -> (String, [SpokenWord]) in
                        var text = "", words: [SpokenWord] = []
                        for try await r in transcriber.results where r.isFinal { text += String(r.text.characters); words += WordTimes.words(r.text) }
                        return (text, words)
                    }
                    try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: wav), finishAfterFile: true)
                    let (text, words) = try await collect.value
                    report("notes transcribe again (Apple)", words, seconds: seconds, texts: ["transcript": text])
                } catch { Log.error("WordsCheck: Apple's recognizer on the file failed: \(error)") }
            }
            try? FileManager.default.removeItem(at: wav)
            Log.info("WordsCheck: done")
            exit(0)
        }
    }

    /// Words in order, inside the recording, and how much of each text they light.
    static func report(_ what: String, _ words: [SpokenWord], seconds: Double, texts: [String: String]) {
        let ordered = zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start + 0.01 } && words.allSatisfy { $0.start <= $0.end }
        let inside = words.allSatisfy { $0.start >= 0 && $0.end <= seconds + 0.5 }
        let sample = words.prefix(4).map { String(format: "%@ %.2f–%.2f", $0.text, $0.start, $0.end) }.joined(separator: ", ")
        var line = "WordsCheck: \(what): \(words.count) words, in order \(ordered), inside the \(String(format: "%.1f", seconds)) s \(inside); \(sample)"
        for (name, text) in texts.sorted(by: { $0.key < $1.key }) {
            let total = WordTimes.tokens(text).count
            line += "; \(name) \(WordTimes.align(text, words).count)/\(total) words lit"
        }
        Log.info(line)
    }
}
#endif
