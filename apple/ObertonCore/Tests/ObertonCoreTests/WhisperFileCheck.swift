import Foundation
@testable import ObertonCore

/// The whole-file paths of `WhisperQuirksCheck`: History's Run again, and Extended Notes' transcribe again.
enum WhisperFileCheck {
    static func transcribe(_ url: URL, settings: AppSettings) async throws -> String {
        try await WhisperAudio.rerun(url, model: settings.whisperModel!, language: settings.whisperLanguage,
                                     vocabulary: settings.vocabularyHint, even: settings.evenOutVolume)
    }

    static func redo(_ url: URL, settings: AppSettings) async throws -> String? {
        try await WhisperAudio.redo(url, model: settings.whisperModel!, language: settings.whisperLanguage,
                                    vocabulary: settings.vocabularyHint, even: settings.evenOutVolume).map(\.text).joined(separator: " ")
    }
}
