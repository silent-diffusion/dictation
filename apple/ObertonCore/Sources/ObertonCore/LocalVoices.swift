import Foundation
import OnnxRuntimeBindings

/// Kokoro v1.0 and Piper on ONNX Runtime's CPU provider (Windows runs the same files in its Python voice server). One
/// short piece of text per call; the audio comes back as mono floats at `SpeechAudio.sampleRate`, at the pace asked
/// for (the voices pace themselves between 0.5× and 2×; the player stretches the rest). Loaded on first use and kept
/// until `unload()` (Settings › Model unloading). Calls are serialized by the caller (`SpeechVoices`).
final class KokoroSpeech: @unchecked Sendable {
    static let maxTokens = 510

    private var session: ORTSession?
    private var inputNames: Set<String> = []
    private var styles: [String: [Float]] = [:]
    private var voicesFile: Data?

    var isLoaded: Bool { session != nil }

    func unload() {
        session = nil
        styles = [:]
        voicesFile = nil
    }

    private func load() throws {
        if session != nil { return }
        do {
            let s = try ORTSession(env: OnnxEnvironment.shared(), modelPath: VoiceInstaller.kokoroModel.path,
                                   sessionOptions: OnnxEnvironment.options())
            inputNames = Set(try s.inputNames())
            voicesFile = try Data(contentsOf: VoiceInstaller.kokoroVoices, options: .alwaysMapped)
            session = s
            // Warm-up, and a check that the model really works ("Ready.", as the Windows voice server does at start).
            _ = try run(Self.tokens("ɹˈɛdi."), voice: VoiceCatalog.defaultVoice, speed: 1)
            CoreLog.info("Kokoro loaded (inputs: \(inputNames.sorted().joined(separator: ", ")))")
        } catch {
            session = nil
            styles = [:]
            voicesFile = nil
            CoreLog.error("Kokoro failed to load: \(error.localizedDescription)")
            throw UserFacingError("The voice model could not be loaded. Try downloading the voice again under Read aloud.")
        }
    }

    /// The voice's style vectors (510 × 256: one per phoneme count), from voices-v1.0.bin (a NumPy .npz).
    private func style(_ voice: String) throws -> [Float] {
        if let s = styles[voice] { return s }
        guard let file = voicesFile, let s = NPZ.array(named: voice + ".npy", in: file), s.count == Self.maxTokens * 256 else {
            if voice != VoiceCatalog.defaultVoice { return try style(VoiceCatalog.defaultVoice) } // as the Windows server does
            throw UserFacingError("The voice model could not be loaded. Try downloading the voice again under Read aloud.")
        }
        styles[voice] = s
        return s
    }

    /// Speak `text` with a Kokoro voice ("af_heart"; "b…" voices are British). A voice the file doesn't have reads as
    /// Heart, in American English (the Windows server swaps the voice before choosing the language). As kokoro-onnx
    /// does: the phonemes in batches split at punctuation, each batch's audio trimmed of its silence at both ends.
    func synthesize(_ text: String, voice: String, speed: Double) throws -> [Float] {
        try load()
        _ = try style(voice)
        let voice = styles[voice] != nil ? voice : VoiceCatalog.defaultVoice
        let british = voice.hasPrefix("b")
        let phonemes = try Phonemizer.shared(british: british).kokoro(text)
        var audio: [Float] = []
        for batch in Self.batches(phonemes) {
            var part: [Float] = []
            for chunk in Self.chunks(Self.tokens(batch)) where !chunk.isEmpty {
                part += try run(chunk, voice: voice, speed: speed)
            }
            audio += Self.trimSilence(part)
        }
        return audio
    }

    /// kokoro-onnx's _split_phonemes: parts between . , ! ? ; joined back (the mark kept on the part before it) into
    /// batches shorter than 510 phonemes.
    static func batches(_ phonemes: String) -> [String] {
        var out: [String] = []
        var current = ""
        var part = ""
        func add(_ raw: String) {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return }
            if current.unicodeScalars.count + p.unicodeScalars.count + 1 >= maxTokens {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = p
            } else if p.count == 1, ".,!?;".contains(p) {
                current += p
            } else {
                if !current.isEmpty { current += " " }
                current += p
            }
        }
        for c in phonemes {
            if ".,!?;".contains(c) { add(part); add(String(c)); part = "" } else { part.append(c) }
        }
        add(part)
        if !current.isEmpty { out.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out
    }

    /// kokoro-onnx's trim (librosa.effects.trim): drop the start and end whose loudness (RMS of 2048-sample frames,
    /// every 512, centred) is more than 60 dB below the loudest frame.
    static func trimSilence(_ y: [Float], topDb: Float = 60, frame: Int = 2048, hop: Int = 512) -> [Float] {
        guard !y.isEmpty else { return y }
        let frames = 1 + y.count / hop
        var rms = [Float](repeating: 0, count: frames)
        y.withUnsafeBufferPointer { p in
            for i in 0..<frames {
                let from = i * hop - frame / 2
                var sum: Float = 0
                for j in max(0, from)..<min(p.count, from + frame) { sum += p[j] * p[j] }
                rms[i] = (sum / Float(frame)).squareRoot()
            }
        }
        guard let loudest = rms.max(), loudest > 0 else { return [] }
        let threshold = loudest * pow(10, -topDb / 20)
        guard let first = rms.firstIndex(where: { $0 > threshold }), let last = rms.lastIndex(where: { $0 > threshold }) else { return [] }
        let start = min(first * hop, y.count), end = min(y.count, (last + 1) * hop)
        return start < end ? Array(y[start..<end]) : []
    }

    private func run(_ tokens: [Int64], voice: String, speed: Double) throws -> [Float] {
        guard let session else { return [] }
        let style = try style(voice)
        let row = Array(style[(tokens.count * 256)..<(tokens.count * 256 + 256)])
        let padded: [Int64] = [0] + tokens + [0]
        let idsName = inputNames.contains("input_ids") ? "input_ids" : "tokens"
        let ids = try ORTValue(tensorData: NSMutableData(data: padded.withUnsafeBytes { Data($0) }), elementType: .int64,
                               shape: [1, NSNumber(value: padded.count)])
        let styleValue = try ORTValue(tensorData: NSMutableData(data: row.withUnsafeBytes { Data($0) }), elementType: .float,
                                      shape: [1, 256])
        let speedValue = try ORTValue(tensorData: NSMutableData(data: [Float(speed)].withUnsafeBytes { Data($0) }), elementType: .float,
                                      shape: [1])
        let outputs = try session.run(withInputs: [idsName: ids, "style": styleValue, "speed": speedValue],
                                      outputNames: Set(try session.outputNames()), runOptions: nil)
        guard let out = outputs.values.first else { return [] }
        return OnnxEnvironment.floats(try out.tensorData() as Data)
    }

    /// Phonemes → Kokoro's token ids (its config.json vocab); anything else is left out.
    static func tokens(_ phonemes: String) -> [Int64] {
        phonemes.unicodeScalars.compactMap { vocab[Character($0)].map(Int64.init) }
    }

    /// At most 510 tokens per call, split after a space (kokoro-onnx splits the same way).
    static func chunks(_ tokens: [Int64]) -> [[Int64]] {
        var out: [[Int64]] = []
        var rest = tokens[...]
        let space = Int64(vocab[" "]!)
        while rest.count > maxTokens {
            let window = rest.prefix(maxTokens)
            let cut = window.lastIndex(of: space).map { $0 + 1 } ?? window.endIndex
            out.append(Array(rest[rest.startIndex..<cut]))
            rest = rest[cut...]
        }
        out.append(Array(rest))
        return out
    }

    /// hexgrad/Kokoro-82M config.json (Apache 2.0).
    static let vocab: [Character: Int] = [
        ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6, "—": 9, "…": 10, "\"": 11, "(": 12, ")": 13, "“": 14, "”": 15,
        " ": 16, "\u{0303}": 17, "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22, "\u{AB67}": 23, "A": 24, "I": 25, "O": 31,
        "Q": 33, "S": 35, "T": 36, "W": 39, "Y": 41, "ᵊ": 42, "a": 43, "b": 44, "c": 45, "d": 46, "e": 47, "f": 48,
        "h": 50, "i": 51, "j": 52, "k": 53, "l": 54, "m": 55, "n": 56, "o": 57, "p": 58, "q": 59, "r": 60, "s": 61,
        "t": 62, "u": 63, "v": 64, "w": 65, "x": 66, "y": 67, "z": 68, "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72, "β": 75,
        "ɔ": 76, "ɕ": 77, "ç": 78, "ɖ": 80, "ð": 81, "ʤ": 82, "ə": 83, "ɚ": 85, "ɛ": 86, "ɜ": 87, "ɟ": 90, "ɡ": 92,
        "ɥ": 99, "ɨ": 101, "ɪ": 102, "ʝ": 103, "ɯ": 110, "ɰ": 111, "ŋ": 112, "ɳ": 113, "ɲ": 114, "ɴ": 115, "ø": 116,
        "ɸ": 118, "θ": 119, "œ": 120, "ɹ": 123, "ɾ": 125, "ɻ": 126, "ʁ": 128, "ɽ": 129, "ʂ": 130, "ʃ": 131, "ʈ": 132,
        "ʧ": 133, "ʊ": 135, "ʋ": 136, "ʌ": 138, "ɣ": 139, "ɤ": 140, "χ": 142, "ʎ": 143, "ʒ": 147, "ʔ": 148, "ˈ": 156,
        "ˌ": 157, "ː": 158, "ʰ": 162, "ʲ": 164, "↓": 169, "→": 171, "↗": 172, "↘": 173, "ᵻ": 177,
    ]
}

/// One Piper voice: <name>.onnx with its <name>.onnx.json config (Windows' tts_server.py PiperVoice).
final class PiperSpeech: @unchecked Sendable {
    let name: String
    private let session: ORTSession
    private let inputNames: Set<String>
    let rate: Int
    private let ids: [String: [Int64]]
    private let british: Bool
    private let noise: Float, length: Float, noiseW: Float

    init(name: String) throws {
        self.name = name
        do {
            let data = try Data(contentsOf: VoiceInstaller.piperConfig(name))
            guard let cfg = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audio = cfg["audio"] as? [String: Any], let rate = audio["sample_rate"] as? Int,
                  let map = cfg["phoneme_id_map"] as? [String: [Int]] else { throw CocoaError(.fileReadCorruptFile) }
            self.rate = rate
            ids = map.mapValues { $0.map(Int64.init) }
            british = ((cfg["espeak"] as? [String: Any])?["voice"] as? String ?? "en-us").hasPrefix("en-gb")
            let inference = cfg["inference"] as? [String: Any] ?? [:]
            noise = Float(inference["noise_scale"] as? Double ?? 0.667)
            length = Float(inference["length_scale"] as? Double ?? 1.0)
            noiseW = Float(inference["noise_w"] as? Double ?? 0.8)
            session = try ORTSession(env: OnnxEnvironment.shared(), modelPath: VoiceInstaller.piperFile(name).path,
                                     sessionOptions: OnnxEnvironment.options())
            inputNames = Set(try session.inputNames())
        } catch {
            // The Windows server loads a Piper voice when it is first asked to speak, so its error comes back as a
            // reading error.
            CoreLog.error("Piper voice \(name) failed to load: \(error.localizedDescription)")
            throw UserFacingError("The voice engine couldn't read that: \(error.localizedDescription)")
        }
    }

    /// As Piper does it: start, then each phoneme followed by padding, then end.
    func toIDs(_ phonemes: String) -> [Int64] {
        var out = ids["^"] ?? []
        let pad = ids["_"] ?? []
        for scalar in phonemes.decomposedStringWithCanonicalMapping.unicodeScalars {
            if let id = ids[String(scalar)] { out += id + pad }
        }
        return out + (ids["$"] ?? [])
    }

    func synthesize(_ text: String, speed: Double) throws -> [Float] {
        let phonemes = try Phonemizer.shared(british: british).piper(text)
        let tokens = toIDs(phonemes)
        let input = try ORTValue(tensorData: NSMutableData(data: tokens.withUnsafeBytes { Data($0) }), elementType: .int64,
                                 shape: [1, NSNumber(value: tokens.count)])
        let lengths = try ORTValue(tensorData: NSMutableData(data: [Int64(tokens.count)].withUnsafeBytes { Data($0) }),
                                   elementType: .int64, shape: [1])
        let scales = try ORTValue(tensorData: NSMutableData(data: [noise, length / Float(speed), noiseW].withUnsafeBytes { Data($0) }),
                                  elementType: .float, shape: [3])
        var feeds = ["input": input, "input_lengths": lengths, "scales": scales]
        if inputNames.contains("sid") {
            feeds["sid"] = try ORTValue(tensorData: NSMutableData(data: [Int64(0)].withUnsafeBytes { Data($0) }), elementType: .int64, shape: [1])
        }
        let outputs = try session.run(withInputs: feeds, outputNames: Set(try session.outputNames()), runOptions: nil)
        guard let out = outputs.values.first else { return [] }
        return SpeechAudio.resample(OnnxEnvironment.floats(try out.tensorData() as Data), from: rate)
    }
}

enum OnnxEnvironment {
    nonisolated(unsafe) private static var env: ORTEnv?
    private static let lock = NSLock()

    static func shared() throws -> ORTEnv {
        try lock.withLock {
            if let env { return env }
            let e = try ORTEnv(loggingLevel: .warning)
            env = e
            return e
        }
    }

    static func options() throws -> ORTSessionOptions {
        let o = try ORTSessionOptions()
        try o.setGraphOptimizationLevel(.all)
        // Threads: ONNX Runtime's own choice, as the Windows server leaves it.
        return o
    }

    /// Little-endian float32 bytes as floats (copied: the bytes need not be aligned).
    static func floats(_ data: Data) -> [Float] {
        let n = data.count / 4
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBytes { _ = data.copyBytes(to: $0, from: data.startIndex..<(data.startIndex + n * 4)) }
        return out
    }
}

/// Reads one array out of a NumPy .npz (a zip of .npy files, stored without compression, as kokoro-onnx's voices
/// file is): finds the member's name, then its .npy header, and returns the float32 data that follows.
enum NPZ {
    static func array(named name: String, in file: Data) -> [Float]? {
        let file = file.startIndex == 0 ? file : Data(file)
        guard let nameData = name.data(using: .utf8), let at = file.range(of: nameData) else { return nil }
        let magic = Data([0x93]) + "NUMPY".data(using: .ascii)!
        guard let m = file.range(of: magic, in: at.upperBound..<min(file.count, at.upperBound + 512)) else { return nil }
        let base = m.lowerBound
        let major = file[base + 6]
        let headerLength: Int
        let start: Int
        if major == 1 {
            headerLength = Int(file[base + 8]) | Int(file[base + 9]) << 8
            start = base + 10 + headerLength
        } else {
            headerLength = Int(file[base + 8]) | Int(file[base + 9]) << 8 | Int(file[base + 10]) << 16 | Int(file[base + 11]) << 24
            start = base + 12 + headerLength
        }
        let header = String(decoding: file[(start - headerLength)..<start], as: UTF8.self)
        guard header.contains("<f4"), !header.contains("'fortran_order': True"),
              let shape = header.range(of: #"\(([0-9, ]*)\)"#, options: .regularExpression) else { return nil }
        let count = header[shape].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.reduce(1, *)
        guard start + count * 4 <= file.count else { return nil }
        return OnnxEnvironment.floats(file[start..<(start + count * 4)])
    }
}
