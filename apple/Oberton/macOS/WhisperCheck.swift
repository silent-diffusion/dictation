#if os(macOS) && DEBUG
import Combine
import Foundation
import ObertonCore

/// Debug only: downloads a Whisper model, then runs a dictation, an Extended Notes stream and a file transcription on a
/// WAV made with `say` (played in place of the microphone), unloads it, puts the setting back, deletes the model if it
/// wasn't there before, and quits. `OBERTON_WHISPER_CHECK=base.en OBERTON_DATA_DIR=<folder inside the container>`.
/// Results go to the log (`/usr/bin/log show --predicate 'subsystem == "com.silentdiffusion.oberton"'`).
@MainActor
enum WhisperCheck {
    static let words = "The quick brown fox jumps over the lazy dog. Oberton writes down what you say, on this Mac. " +
        "Whisper hears each sentence, and the notes keep them in order. This is the end of the test."

    static func run(_ model: AppModel, id: String) {
        Task { @MainActor in
            Log.info("WhisperCheck: \(id), data in \(AppPaths.dataDir.path)")
            let had = WhisperModels.isDownloaded(id)
            if !had {
                model.downloadWhisper(id)
                var shown = -1
                while let d = model.whisperDownload {
                    let pct = Int((d.fraction ?? 0) * 100)
                    if pct / 20 != shown / 20 { Log.info("WhisperCheck: downloading \(pct)%"); shown = pct }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if let e = model.whisperDownloadError { Log.error("WhisperCheck: download failed: \(e)"); exit(1) }
            }
            Log.info("WhisperCheck: downloaded = \(WhisperModels.isDownloaded(id)) (was \(had))")

            let wav = FileManager.default.temporaryDirectory.appending(path: "whisper-check.wav")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", words]
            do { try say.run(); say.waitUntilExit() } catch { Log.error("WhisperCheck: say failed: \(error)"); exit(1) }

            let before = model.settings.speechModel
            model.useSpeechModel(id)
            // Loads now (warm-up); the dictation below then shows its running transcript from the start.
            for _ in 0..<600 where WhisperEngine.loadedModel != id || !model.speechOK { try? await Task.sleep(for: .milliseconds(200)) }
            Log.info("WhisperCheck: status \"\(model.speechStatus)\", loaded \(WhisperEngine.loadedModel ?? "none"), engine \(model.speechEngineName)")

            // A dictation, the WAV in place of the microphone.
            LiveTranscriber.fakeAudio = wav
            var partials: [String] = []
            let watch = model.$liveText.removeDuplicates().sink { if !$0.isEmpty { partials.append($0) } }
            let seconds = (try? WhisperAudio.samples(wav).count).map { Double($0) / 16_000 } ?? 10
            model.start()
            try? await Task.sleep(for: .seconds(seconds + 0.7))
            model.stop()
            for _ in 0..<600 where model.phase.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            watch.cancel()
            LiveTranscriber.fakeAudio = nil
            Log.info("WhisperCheck: dictation \(model.phase.label); \(partials.count) running transcripts while speaking: \(partials.dropLast().map { "\"\($0)\"" }.joined(separator: " → "))")
            Log.info("WhisperCheck: dictation heard \"\(model.lastEntry?.transcription ?? "(nothing)")\"")

            // Extended Notes' live stream, fed in real time.
            let samples = (try? WhisperAudio.samples(wav)) ?? []
            final class Pieces: @unchecked Sendable { var list: [String] = []; let lock = NSLock() }
            let pieces = Pieces()
            let stream = WhisperLiveStream(model: id, language: model.settings.whisperLanguage, vocabulary: "Oberton") { text, at in
                pieces.lock.withLock { pieces.list.append(String(format: "[%.1f s] ", at) + text) }
            }
            stream.start()
            for from in stride(from: 0, to: samples.count, by: 4_000) {
                stream.append(Array(samples[from..<min(samples.count, from + 4_000)]))
                try? await Task.sleep(for: .milliseconds(250))
            }
            let last = await stream.finish()
            let live = pieces.lock.withLock { pieces.list }
            Log.info("WhisperCheck: notes committed \(live.count) while listening: \(live.joined(separator: " | ")); at the end: \(last.map { String(format: "[%.1f s] ", $0.at) + $0.text } ?? "nothing")")

            // Transcribe again from the file (Extended Notes' redo, History's Run again).
            do {
                let again = try await WhisperAudio.redo(wav, model: id, language: model.settings.whisperLanguage, vocabulary: "Oberton", even: true)
                Log.info("WhisperCheck: from the file: \(again.map { String(format: "[%.1f s] ", $0.seconds) + $0.text }.joined(separator: " "))")
                let rerun = try await WhisperAudio.rerun(wav, model: id, language: model.settings.whisperLanguage, vocabulary: "Oberton", even: true)
                Log.info("WhisperCheck: Run again: \(rerun)")
            } catch { Log.error("WhisperCheck: from the file failed: \(error)") }

            let unloaded = await model.unloadNow(speech: true, ai: false, voice: false)
            Log.info("WhisperCheck: unload now: \(unloaded) Loaded after: \(WhisperEngine.loadedModel ?? "none"), speechLoaded \(model.speechLoaded)")

            model.settings.speechModel = before
            if !had {
                do { try WhisperModels.remove(id) } catch { Log.error("WhisperCheck: couldn't delete \(id): \(error)") }
            }
            try? FileManager.default.removeItem(at: wav)
            // The scratch data folder (settings, history) goes too.
            if ProcessInfo.processInfo.environment["OBERTON_DATA_DIR"] != nil { try? FileManager.default.removeItem(at: AppPaths.dataDir) }
            Log.info("WhisperCheck: done; \(id) downloaded now = \(WhisperModels.isDownloaded(id)), setting back to \"\(before)\"")
            exit(0)
        }
    }
}
#endif
