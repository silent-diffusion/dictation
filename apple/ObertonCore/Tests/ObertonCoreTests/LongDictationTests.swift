import AVFoundation
import Foundation
import Testing
@testable import ObertonCore

/// A long dictation keeps every line: the running transcript in the pill follows the speech to its end, and the final
/// text holds every sentence. TestFlight 5.18.1 (2) stopped refreshing the running transcript after one decode slower
/// than 4 s (large-v3 turbo takes about that over 20 s of speech), so the pill kept showing the first line.
@Suite struct LongDictationTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    /// A quarter second of 16 kHz audio whose samples all hold `value` (which second of the recording it is).
    static func quarter(_ value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000)!
        buffer.frameLength = 4_000
        for i in 0..<4_000 { buffer.floatChannelData![0][i] = value }
        return buffer
    }

    /// Each refresh is slow (0.4 s here; `OBERTON_PARTIAL_DELAY=4.5` reproduces build 2 with large-v3 turbo), yet
    /// refreshes keep coming and the last one before the stop has the last seconds said.
    @Test func runningTranscriptFollowsTheSpeechToTheEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        let delay = Double(env["OBERTON_PARTIAL_DELAY"] ?? "") ?? 0.4
        let seconds = Int(env["OBERTON_PARTIAL_SECONDS"] ?? "") ?? 8
        let seen = Seen()
        let dictation = WhisperDictation(model: "test", language: nil, prompt: "", even: false) { seen.add($0) }
        dictation.partialDecode = { tail in
            try await Task.sleep(for: .seconds(delay))
            return "second \(Int(tail.last ?? -1))"
        }
        dictation.startPartials()
        for q in 0..<(seconds * 4) {
            dictation.append(Self.quarter(Float(q / 4)))
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .seconds(delay + 0.6))
        dictation.cancel()
        let texts = seen.all
        #expect(texts.count >= 3, "refreshes: \(texts)")
        // The newest refresh is about the last seconds said (at most one decode behind).
        let newest = Int(texts.last?.split(separator: " ").last ?? "") ?? -1
        #expect(newest >= seconds - 2 - Int(delay.rounded(.up)), "refreshes: \(texts)")
    }

    /// The pill shows the newest words of a long transcript (the last three lines' worth), never just its start.
    @Test func pillShowsTheNewestWords() {
        let sentences = (1...12).map { "Sentence number \($0) says something about the day ahead." }
        let text = sentences.joined(separator: " ")
        let shown = LiveTail.tail(text)
        #expect(shown.hasPrefix("…"))
        #expect(shown.hasSuffix(sentences.last!))
        #expect(!shown.contains("number 1 says"))
        #expect(shown.count <= LiveTail.characters + 1)
        #expect(text.hasSuffix(shown.dropFirst().drop(while: \.isWhitespace)))
        // Short text is shown whole.
        #expect(LiveTail.tail("Just a few words.") == "Just a few words.")
    }

    /// Pieces settled one after another (Apple Speech's finished results, live typing's pieces) are all kept.
    @Test func everyPieceIsKept() {
        let pieces = ["This is the first sentence.", "Now the second one,", "which goes on", "And the third sentence ends it."]
        let joined = FragmentStitcher.join(pieces)
        for word in ["first", "second", "goes on", "third sentence ends it."] { #expect(joined.contains(word), "\(joined)") }
        let stitched = LiveStitch.stitch(raw: pieces.joined(separator: " "), pieces: Array(pieces.dropLast()), tail: pieces.last!)
        #expect(stitched == joined)
    }
}

/// A real long recording (several sentences with pauses) through the dictation paths, as AppModel runs them: Whisper
/// (the debug fake-audio hook, in real time) and Apple Speech. Only when asked:
/// `say -o long.aiff "…five sentences with [[slnc 2000]] pauses…"; afconvert -f WAVE -d LEI16@16000 -c 1 long.aiff long.wav`
/// `OBERTON_LONG_DICTATION=long.wav OBERTON_LONG_ENGINES=base.en,apple OBERTON_DATA_DIR=<scratch> swift test --filter LongDictationCheck`
/// The sentences must each hold one of `OBERTON_LONG_MARKERS` (default: first,second,third,fourth,fifth).
@Suite(.serialized) struct LongDictationCheck {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_LONG_DICTATION"] != nil))
    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let clip = URL(fileURLWithPath: env["OBERTON_LONG_DICTATION"]!)
        let markers = (env["OBERTON_LONG_MARKERS"] ?? "first,second,third,fourth,fifth").split(separator: ",").map(String.init)
        let seconds = Double(try WhisperAudio.samples(clip).count) / 16_000
        for engine in (env["OBERTON_LONG_ENGINES"] ?? "base.en").split(separator: ",").map(String.init) {
            let apple = engine == "apple"
            if !apple {
                if !WhisperModels.isDownloaded(engine) { try await WhisperModels.download(engine) { _ in } }
                try await WhisperEngine.shared.load(engine)
            }
            let t = LiveTranscriber()
            var recording = true
            var live: [String] = []
            t.onText = { if recording { live.append($0) } }
            LiveTranscriber.fakeAudio = clip
            try t.startRecording(microphone: nil, evenOut: false)
            if apple {
                try await t.startRecognizer(locale: Locale(identifier: "en-US"), vocabulary: [])
            } else {
                try await t.startWhisper(model: engine, language: "en", prompt: "")
            }
            try await Task.sleep(for: .seconds(seconds + 1))
            recording = false
            t.stopRecording()
            let final = await t.stop()
            LiveTranscriber.fakeAudio = nil
            print("LONG \(engine) final: \(final)")
            print("LONG \(engine) live (\(live.count) updates), last: \(live.last ?? "")")
            for m in markers { #expect(final.localizedCaseInsensitiveContains(m), "\(engine) final lost “\(m)”: \(final)") }
            // The pill's newest words are from the last sentence, not the first line.
            #expect(LiveTail.tail(live.last ?? "").localizedCaseInsensitiveContains(markers.last!), "\(engine) live: \(live.last ?? "")")
        }
    }
}
