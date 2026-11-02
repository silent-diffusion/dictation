import ObertonCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Clipboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}

/// The capitalized monospaced label the Windows app uses for every section ("DICTATE", "AI EDIT"), with its
/// decorative Japanese word beside it (hidden from VoiceOver, as there).
struct PanelLabel: View {
    var title: String
    var japanese: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(.caption, design: .monospaced).weight(.semibold)).tracking(1.2)
            if let japanese { Text(japanese).font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .foregroundStyle(.secondary)
    }
}

/// One of the three boxes used everywhere (the receipt, History, Try it): a label, the text, and Copy.
struct TextBox<Content: View>: View {
    var title: String
    var copyText: String
    var emphasized = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PanelLabel(title: title)
                Spacer()
                Button("Copy") { Clipboard.copy(copyText) }
                    .font(.system(.caption, design: .monospaced))
                    .buttonStyle(.borderless)
            }
            content
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .opacity(emphasized ? 1 : 0.6)
    }
}

/// The AI's edit drawn against what was heard: removed words struck through, added words in the accent color.
struct DiffText: View {
    var original: String
    var edited: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (i, token) in WordDiff.compute(original, edited).enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var word = AttributedString(token.word)
            switch token.kind {
            case .same: break
            case .removed:
                word.strikethroughStyle = .single
                word.foregroundColor = .secondary
            case .added:
                word.foregroundColor = .accentColor
                word.backgroundColor = .accentColor.opacity(0.12)
            }
            out += word
        }
        return out
    }
}

/// Transcription, AI Edit and Inserted, for one dictation.
struct ReceiptView: View {
    var entry: HistoryEntry
    var focusInserted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextBox(title: "Transcription", copyText: entry.transcription, emphasized: !focusInserted) {
                Text(entry.transcription)
            }
            if let edit = entry.aiEdit {
                TextBox(title: "AI Edit", copyText: edit, emphasized: !focusInserted) {
                    DiffText(original: entry.transcription, edited: edit)
                }
            }
            TextBox(title: "Inserted", copyText: entry.inserted) {
                Text(entry.inserted).font(focusInserted ? .title3 : .body)
            }
            if let warning = entry.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
        }
    }
}

/// A row of block bars for the microphone level, like the Windows overlay's meter.
struct LevelMeter: View {
    var level: Float
    var bars = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(i) / Float(bars) < level ? Color.primary : Color.primary.opacity(0.15))
                    .frame(width: 3, height: 12)
            }
        }
        .accessibilityHidden(true)
    }
}

extension AppModel.Phase {
    var label: String {
        switch self {
        case .idle: "Ready"
        case .starting: "Starting…"
        case .recording: "Listening"
        case .transcribing: "Transcribing…"
        case .processing: "Tidying up…"
        case .preview: "Preview"
        case .inserting: "Inserting…"
        case .done(let s): s
        case .failed(let s): s
        }
    }
}
