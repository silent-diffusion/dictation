import CoreML
import Foundation
import Testing
import WhisperKit
@testable import ObertonCore

/// Load and transcription times per model and compute units on this Mac. Only when asked:
/// `OBERTON_WHISPER_BENCH=<wav> OBERTON_WHISPER_MODELS=base.en,small.en OBERTON_DATA_DIR=<scratch> swift test --filter WhisperBenchmark`.
@Suite(.serialized) struct WhisperBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBERTON_WHISPER_BENCH"] != nil))
    func loadAndTranscribe() async throws {
        let env = ProcessInfo.processInfo.environment
        let samples = try WhisperAudio.samples(URL(fileURLWithPath: env["OBERTON_WHISPER_BENCH"]!))
        let seconds = Double(samples.count) / 16_000
        let units: [(String, MLComputeUnits, MLComputeUnits)] = (env["OBERTON_WHISPER_UNITS"] ?? "ane,gpu,gpu+ane").split(separator: ",").map {
            switch $0 {
            case "ane": ("ane", .cpuAndNeuralEngine, .cpuAndNeuralEngine)
            case "gpu": ("gpu", .cpuAndGPU, .cpuAndGPU)
            default: ("gpu+ane", .cpuAndGPU, .cpuAndNeuralEngine)
            }
        }
        for id in (env["OBERTON_WHISPER_MODELS"] ?? "base.en").split(separator: ",").map(String.init) {
            if !WhisperModels.isDownloaded(id) {
                let t = Date()
                try await WhisperModels.download(id) { _ in }
                print("BENCH \(id): downloaded in \(Int(Date().timeIntervalSince(t))) s")
            }
            let m = try #require(WhisperModels.model(id))
            for (name, encoder, decoder) in units {
                for pass in 1...2 {
                    let t0 = Date()
                    let config = WhisperKitConfig(modelFolder: WhisperModels.folder(m).path, tokenizerFolder: WhisperModels.baseDir,
                                                  computeOptions: ModelComputeOptions(audioEncoderCompute: encoder, textDecoderCompute: decoder),
                                                  verbose: false, logLevel: .none, prewarm: false, load: true, download: false)
                    let kit = try await WhisperKit(config)
                    let load = Date().timeIntervalSince(t0)
                    let t1 = Date()
                    let r = try await kit.transcribe(audioArray: samples, decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true))
                    let run = Date().timeIntervalSince(t1)
                    let t2 = Date()
                    _ = try await kit.transcribe(audioArray: Array(samples.prefix(16_000 * 5)), decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true))
                    let short = Date().timeIntervalSince(t2)
                    print(String(format: "BENCH %@ %@ pass %d: load %.1f s, %.0f s audio in %.2f s (RTF %.3f), 5 s clip %.2f s | %@",
                                 id, name, pass, load, seconds, run, run / seconds, short, String(r.map(\.text).joined().prefix(60))))
                    await kit.unloadModels()
                }
            }
        }
    }
}
