import ObertonCore
import SwiftUI

// MARK: - B // Models & AI

/// B.4 Model unloading (Windows UnloadingPage.xaml): when idle models are let go, the "No waiting" card, UNLOAD NOW,
/// and what is loaded now. The timer itself is `ModelUnloader`.
struct UnloadingSection: View {
    @EnvironmentObject var model: AppModel
    @State private var result = ""
    /// The buttons whose unloading is under way (only the clicked one is disabled).
    @State private var busy: Set<String> = []

    private static let choices: [(Int, String)] = [
        (AppSettings.unloadImmediately, "Immediately after use"), (1, "1 minute"), (3, "3 minutes"), (5, "5 minutes"),
        (10, "10 minutes"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"), (240, "4 hours"),
        (0, "Never (keep loaded)"),
    ]

    /// A hand-edited value that isn't in the list shows as itself, first (as on Windows).
    private var choices: [(Int, String)] {
        let m = model.settings.unloadAfterMinutes
        return Self.choices.contains { $0.0 == m } ? Self.choices : [(m, "\(m) minutes")] + Self.choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Models take memory while they are loaded (several GB of GPU memory for speech recognition and the AI). Oberton can unload them when you haven't used them for a while.")

            FieldLabel("Unload a model after it has been unused for").padding(.top, -8)
            ObMenu(options: choices, selection: $model.settings.unloadAfterMinutes).frame(width: 240)
            Caption("Applies to the speech recognition model, the local AI model and the Read aloud voice. \"Immediately after use\" frees them a few seconds after each dictation or reading ends (they stay loaded while in use).", bottom: 0)
                .padding(.top, 8)

            Box(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("No waiting when you dictate").font(Ob.sans(Ob.body, .semibold))
                    Caption("Press the hotkey and start talking right away, even if a model was unloaded. Recording starts at once; the speech model loads meanwhile (a few seconds) and then catches up on everything you said. The AI model loads while you speak, too.", bottom: 0)
                        .padding(.top, 4)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            }
            .padding(.top, 16)

            FieldLabel("Unload now").padding(.top, 2)
            Box(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Caption("Free the memory right away instead of waiting. Each model loads again by itself the next time it's needed.", bottom: 10)
                    FlowButtons {
                        unloadButton("Unload everything", "all", primary: true)
                        unloadButton("Speech model", "speech")
                        unloadButton("AI model", "ai")
                        unloadButton("Read aloud voice", "voice")
                    }
                    .padding(.bottom, 8)
                    // Always there, empty until a button is used.
                    Caption(result.isEmpty ? " " : result, bottom: 0).padding(.top, 4)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            }

            // The footer's own lines (Status.Speech, Status.Ai).
            Caption("Now: \(model.speechStatus)\n\(model.aiStatusLine.text)\nRead aloud voice: \(model.reader.isLoaded ? "loaded" : "not loaded")", bottom: 0)
                .padding(.top, 16)
        }
    }

    private func unloadButton(_ title: String, _ what: String, primary: Bool = false) -> some View {
        Button(title) {
            busy.insert(what)
            result = "Unloading…"
            Task {
                result = await model.unloadNow(speech: what == "all" || what == "speech", ai: what == "all" || what == "ai",
                                               voice: what == "all" || what == "voice")
                busy.remove(what)
            }
        }
        .buttonStyle(primary ? .primary : .quiet)
        .disabled(busy.contains(what))
    }
}

/// Buttons that wrap onto a new line when the page is narrow (Windows' WrapPanel), 8 pt apart.
private struct FlowButtons<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        FlowLayout(spacing: 8) { content }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
