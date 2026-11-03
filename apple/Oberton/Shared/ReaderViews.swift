import ObertonCore
import SwiftUI

/// The Read aloud player: READING  VOICE, the text with what has been read bright, the word being spoken in the accent,
/// the rest dim; a progress line; −15 ▮▮ +15, − 1.25× +, and the time left. The speed opens a grid of speeds.
struct ReaderCard: View {
    @ObservedObject var player: ReadAloudPlayer
    var opacity: Double
    @Environment(\.ob) private var ob
    @State private var all = false
    @State private var speeds = false
    @Environment(\.overlayRoom) private var room

    var body: some View {
        if player.isSpeaking {
            WidthCap(width: min(520, room.width)) { card }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("READING").font(Ob.mono(10.5, .semibold)).foregroundStyle(lightText)
                Text(player.voiceName.uppercased()).font(Ob.mono(10.5, .medium)).foregroundStyle(dimText).lineLimit(1)
                Spacer()
                Button { all.toggle() } label: {
                    Text(all ? "⌃ LESS" : "⌄ ALL").font(Ob.mono(10.5)).foregroundStyle(lightText)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(lightText.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { player.stop() } label: { Text("✕").font(Ob.mono(11)).foregroundStyle(lightText) }
                    .buttonStyle(.plain).accessibilityLabel("Stop")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(attributed).font(Ob.sans(15)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading).id("text")
                }
                .frame(maxHeight: all ? 320 : 96)
            }
            .padding(.top, 10).padding(.bottom, 12)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(lightText.opacity(0.25))
                    Rectangle().fill(lightText).frame(width: geo.size.width * player.progress)
                }
            }
            .frame(height: 2).padding(.bottom, 12)
            HStack(spacing: 8) {
                round("−15") { player.skip(seconds: -15) }
                Button { player.togglePause() } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.system(size: 15))
                        .foregroundStyle(Color(hex: 0x161618))
                        .frame(width: 42, height: 42).background(Circle().fill(lightText))
                }
                .buttonStyle(.plain).accessibilityLabel(player.isPaused ? "Play" : "Pause")
                round("+15") { player.skip(seconds: 15) }
                Spacer().frame(width: 14)
                round("−") { player.setSpeed(player.speed - 0.25) }
                Button { speeds.toggle() } label: {
                    Text(speedText(player.speed)).font(Ob.mono(11, .medium)).foregroundStyle(lightText)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $speeds) { speedGrid }
                round("+") { player.setSpeed(player.speed + 0.25) }
                Spacer()
                Text(left).font(Ob.mono(11, .medium)).foregroundStyle(dimText)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(darkInk.opacity(max(opacity, 0.94))))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }

    private func round(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Ob.mono(12, .medium)).foregroundStyle(lightText)
                .frame(width: 30, height: 30).background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private var speedGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed").font(Ob.sans(11)).foregroundStyle(Color.white.opacity(0.6)).padding(.leading, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 6), count: 4), spacing: 6) {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4], id: \.self) { s in
                    let on = abs(s - player.speed) < 0.01
                    Button { player.setSpeed(s); speeds = false } label: {
                        Text(speedText(s)).font(Ob.mono(12)).foregroundStyle(on ? Color(hex: 0x161618) : lightText)
                            .frame(width: 58, height: 30).background(Capsule().fill(on ? .white : Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(Color(hex: 0x202024))
        .presentationBackground(Color(hex: 0x202024))
    }

    private func speedText(_ s: Double) -> String {
        (s == s.rounded() ? String(format: "%.0f", s) : s * 4 == (s * 4).rounded() && s * 2 != (s * 2).rounded() ? String(format: "%.2f", s) : String(format: "%.1f", s)) + "×"
    }

    private var left: String {
        let s = Int(player.secondsLeft.rounded())
        return String(format: "%d:%02d LEFT", s / 60, s % 60)
    }

    private var attributed: AttributedString {
        var s = AttributedString(player.text)
        s.foregroundColor = lightText.opacity(0.45)
        guard let r = player.spokenRange else { return s }
        if let read = Range(NSRange(location: 0, length: r.location), in: s) { s[read].foregroundColor = lightText }
        if let now = Range(r, in: s) {
            s[now].foregroundColor = Color(hex: ob.accentChoice.hex.dark)
            s[now].font = Ob.sans(15, .semibold)
        }
        return s
    }
}
