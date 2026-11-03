import ObertonCore
import SwiftUI

struct AboutSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.ob) private var ob
    @Environment(\.showJapanese) private var showJapanese

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(versionLine).font(Ob.mono(13, .bold)).padding(.bottom, 4)
            (Text("Free and open source (MIT license). ")
                + Text("[Project page on GitHub](https://github.com/silent-diffusion/dictation)").foregroundStyle(ob.ink).underline())
                .font(Ob.sans(13)).foregroundStyle(ob.muted).tint(ob.ink)
            Hairline().padding(.vertical, 16)
            part("D.2.1", "What it is", "概要") {
                prose(whatItIs)
                prose(Text("The name is German for ") + ink("overtone") + Text(": the AI adds a layer of polish on top of your own voice."))
            }
            part("D.2.2", "How it works", "口述") {
                steps(howItWorks)
                prose(Text("If the AI fails or its edit strays too far from what you said (the profile's safety net), your own words are inserted instead, so a dictation is never lost. The dashboard's signal path lights each step while it works. Read aloud uses the voices built into \(Device.system). ")
                      + ink("Nothing leaves your \(Device.noun)")
                      + Text(" unless you turn off Keep everything offline and choose a cloud model; the only other network use is downloading the speech and AI models you pick."))
            }
            part("D.2.3", "How Extended Notes works", "記録") {
                prose(Text("A session runs four steps side by side, each on its own rhythm, so the text keeps up with a lecture of any length while the AI only ever reads as much as fits in its memory at once."))
                notesSteps
                VStack(alignment: .leading, spacing: 8) {
                    Readout("A 30-minute lecture, step by step")
                    NotesTimeline().aspectRatio(760 / 196, contentMode: .fit).frame(maxWidth: 760)
                }
                .padding(.top, 8)
                prose(ink("Why these sizes:") + Text(" the AI model reads at most \(NotesSummary.contextTokens.formatted()) tokens per request, about 9,400 characters or ten minutes of speech, with room left for its instructions and reply. Summing up in sections, then summaries of summaries, keeps every request inside that window however long the session runs. Nothing is sent to the AI while you dictate, so dictation always comes first."))
                prose(ink("The model:") + Text(" by default the largest installed Ollama model that fits the memory this \(Device.noun)'s graphics may use; without one, the active model (Apple Intelligence by default) (Settings › Models › Extended Notes AI). After a session you can play the recording, export it, or click a step at the top of the session to redo it. Extended Notes never counts toward your dictation figures; Analytics shows it in a section of its own."))
            }
            part("D.2.4", "What it keeps", "履歴") {
                prose(Text("Everything stays in Oberton's data folder on this \(Device.noun), apart from the app itself, so updates never touch it:"))
                VStack(alignment: .leading, spacing: 0) {
                    keep("History", "Each dictation's text, AI edit and app, and its recording: by number or by age, text and recordings set apart (Settings › History).")
                    keep("Daily counts", "Numbers only, for the dashboard and Analytics: words, time, turnaround, readings and apps. Never any text, audio or window titles.")
                    keep("Word tally", "Counts of the words, phrases, corrections and fillers you dictate, overall and per app. Never whole sentences. Can be turned off.")
                    keep("Extended notes", "Each session's recording, transcript, formatted text and summary, until you delete it, and its own counts, kept apart from dictation.")
                }
            }
            part("D.2.5", "Design language", "計器", last: true) {
                prose(Text("Oberton is drawn like a ") + ink("printed instrument panel")
                      + Text(": black ink on gray paper, 1px lines and readouts, with no cards or shadows. Dark mode is the same sheet with ink and paper swapped."))
                prose(Text("Color is a signal, not decoration. ") + Text("The accent color marks what is live").foregroundStyle(ob.accent)
                      + Text(": today's count, a countdown, a step at work (its dot pulses), the word being read, words the AI added. ")
                      + ink("Red means the microphone is open") + Text(" and appears nowhere else. You can choose the accent under Appearance."))
                // With the Japanese words turned off there is nothing for the glossary to explain.
                if showJapanese {
                    prose(Text("The small Japanese words beside labels are decoration. Each one matches what it sits next to, and none of them is needed to use the app:"))
                    glossary
                }
            }
        }
    }

    /// "OBERTON 5.18.1", and "// development copy" for a debug build (Windows: running from the source tree).
    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        #if DEBUG
        return "OBERTON \(version)  // DEVELOPMENT COPY"
        #else
        return "OBERTON \(version)"
        #endif
    }

    /// The first paragraph, naming the hotkeys actually set.
    private var whatItIs: Text {
        #if os(macOS)
        Text("Oberton is a dictation and read-aloud app for the Mac that runs entirely on your Mac. ").foregroundStyle(ob.ink)
            + Text("Press ") + Text(model.settings.hotkey).font(Ob.mono(14)).foregroundStyle(ob.ink)
            + Text(", speak, and press it again: cleaned-up text appears at your cursor, in any app. Select text and press ")
            + Text(model.settings.speakHotkey).font(Ob.mono(14)).foregroundStyle(ob.ink)
            + Text(" to hear it read in a natural voice. For a lecture or a meeting, ") + ink("Extended Notes")
            + Text(" listens for as long as it lasts and keeps a transcript, a formatted version and a running summary, with the recording.")
        #else
        Text("Oberton is a dictation and read-aloud app that runs entirely on your iPhone. ").foregroundStyle(ob.ink)
            + Text("Tap Dictate, speak, and tap again: the cleaned-up text is copied, ready to paste in any app. Paste text on the Read aloud page to hear it read in a natural voice. For a lecture or a meeting, ")
            + ink("Extended Notes")
            + Text(" listens for as long as it lasts and keeps a transcript, a formatted version and a running summary, with the recording.")
        #endif
    }

    private var howItWorks: [(String, String)] {
        #if os(macOS)
        [("01 Listen", "Your microphone is recorded while the hotkey is on. The recording is kept in History only if you choose to (Settings › History)."),
         ("02 Transcribe", "Apple Speech turns speech into text as you speak, on this Mac."),
         ("03 Tidy up", "Your profile's AI model edits the text, following its instructions: Apple Intelligence on this Mac, or a local model through Ollama."),
         ("04 Insert", "The text is pasted or typed at your cursor, and your clipboard is put back.")]
        #else
        [("01 Listen", "Your microphone is recorded while you dictate. The recording is kept in History only if you choose to (Settings › History)."),
         ("02 Transcribe", "Apple Speech turns speech into text as you speak, on this iPhone."),
         ("03 Tidy up", "Your profile's AI model edits the text, following its instructions: Apple Intelligence on this iPhone by default."),
         ("04 Insert", "The text is copied, ready to paste.")]
        #endif
    }

    private func ink(_ s: String) -> Text { Text(s).foregroundStyle(ob.ink) }

    private func prose(_ t: Text) -> some View {
        t.font(Ob.sans(14)).lineSpacing(8).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func part<Extra: View>(_ address: String, _ title: String, _ jp: String, last: Bool = false,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Readout(address).frame(width: 64, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(title.uppercased()).font(Ob.mono(12, .bold))
                        Spacer()
                        Decor(jp)
                    }
                    extra()
                }
            }
            if !last { Hairline().padding(.vertical, 16) }
        }
    }

    private func steps(_ s: [(String, String)]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(s.enumerated()), id: \.offset) { i, step in
                if i > 0 { Hairline(vertical: true) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.0.uppercased()).font(Ob.mono(11, .bold))
                    Text(step.1).font(Ob.sans(12.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .overlay(Rectangle().strokeBorder(ob.ink, lineWidth: 1))
    }

    /// The four steps of an Extended Notes session, each with its rhythm in the accent.
    private var notesSteps: some View {
        #if os(macOS)
        let listen = "The microphone, the Mac's own audio, or both, recorded to the session's folder. Type your own lines in, or press the marker key (⚑) to flag a moment."
        #else
        let listen = "The microphone, recorded to the session's folder. Type your own lines in, or tap ⚑ Mark to flag a moment."
        #endif
        let steps: [(String, String, String)] = [
            ("01 Listen", "All the time", listen),
            ("02 Speech", "As each phrase ends", "Apple Speech adds each finished phrase to the transcript, on this \(Device.noun). If the recognizer restarts, up to 3 minutes of audio wait for it."),
            ("03 Format", "Every 110 words · 90 s at most", "The AI adds punctuation, paragraphs and headings to the new words. An edit that adds more than a tenth new words, keeps under 40% of them, or brings in a number is refused, and the words stay as heard."),
            ("04 Summary", "Every ~6 minutes · 10 at most", "Each section of formatted text (about 6,000 characters) is summed up in a sixth of its length; every four summaries fold into one. At Stop: the main idea, three bullets, at most three paragraphs."),
        ]
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 { Hairline(vertical: true) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.0.uppercased()).font(Ob.mono(11, .bold))
                    Text(step.1.uppercased()).font(Ob.mono(11)).foregroundStyle(ob.accent)
                    Text(step.2).font(Ob.sans(12.5)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }

    private func keep(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Readout(k).frame(width: 150, alignment: .leading)
            Text(v).font(Ob.sans(13)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    /// The Japanese words in Oberton and what they mean (AboutPage's glossary).
    private var glossary: some View {
        let words: [(String, String, String, String)] = [
            ("倍音", "baion", "Overtone (Oberton is German for the same thing)", "Sidebar, About"),
            ("計器", "keiki", "Instrument, gauge", "Dashboard"),
            ("口述", "kōjutsu", "Dictation, spoken account", "Speech to text"),
            ("読上", "yomiage", "Reading aloud (short for 読み上げ)", "Read aloud"),
            ("履歴", "rireki", "History, record", "History"),
            ("設定", "settei", "Settings", "Settings and each of its pages"),
            ("概要", "gaiyō", "Overview, about", "This page"),
            ("録音", "rokuon", "Recording", "Overlay, while recording"),
            ("処理中", "shorichū", "Processing", "Overlay, while transcribing and tidying up"),
            ("挿入", "sōnyū", "Insertion", "Overlay, after inserting"),
            ("記録", "kiroku", "Record, notes", "Extended notes"),
            ("分析", "bunseki", "Analysis", "Analytics"),
        ]
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Readout("Word").frame(width: 70, alignment: .leading)
                Readout("Reading").frame(width: 90, alignment: .leading)
                Readout("English").frame(maxWidth: .infinity, alignment: .leading)
                Readout("Where you see it").frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            ForEach(words, id: \.0) { w in
                Hairline()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Decor(w.0, size: 16, color: ob.ink, weight: .bold).frame(width: 70, alignment: .leading)
                    Text(w.1).font(Ob.sans(13).italic()).foregroundStyle(ob.muted).frame(width: 90, alignment: .leading)
                    Text(w.2).font(Ob.sans(13)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Readout(w.3).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The Japanese words in Oberton and what they mean")
    }
}

/// A 30-minute Extended Notes session on a time line, one lane per step: speech commits as each phrase ends (about every
/// 5 s), formatting about every minute (110 words of steady speech), a summary section every ~6.5 minutes (6,000
/// characters), the first four section summaries folded into one, and the final summary at Stop (AboutPage.NotesTimeline).
/// Drawn at 760 × 196 and scaled to fit.
struct NotesTimeline: View {
    @Environment(\.ob) private var ob

    var body: some View {
        DesignSize(width: 760, height: 196) {
            Canvas { ctx, _ in draw(ctx) }
        }
        .accessibilityLabel("A 30-minute lecture, step by step: a sentence every 5 seconds, formatting about every minute, a summary every 6 and a half minutes, the first four summaries folded into one, and the final summary at Stop.")
    }

    private func draw(_ c: GraphicsContext) {
        let x0 = 96.0, x1 = 740.0, minutes = 30.0, h = 196.0
        func x(_ m: Double) -> Double { x0 + (x1 - x0) * m / minutes }
        func text(_ s: String, _ px: Double, _ py: Double, _ size: Double = 10, _ color: Color? = nil, bold: Bool = false) {
            c.draw(Text(s).font(Ob.mono(size, bold ? .bold : .regular)).foregroundStyle(color ?? ob.muted), at: CGPoint(x: px, y: py), anchor: .topLeading)
        }
        func rule(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ color: Color, _ width: Double = 1) {
            var p = Path()
            p.move(to: CGPoint(x: ax, y: ay)); p.addLine(to: CGPoint(x: bx, y: by))
            c.stroke(p, with: .color(color), lineWidth: width)
        }
        func box(_ bx: Double, _ by: Double, _ w: Double, _ bh: Double, _ fill: Color, stroke: Color? = nil) {
            let r = CGRect(x: bx, y: by, width: max(1, w), height: bh)
            c.fill(Path(r), with: .color(fill))
            if let stroke { c.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(stroke), lineWidth: 1) }
        }

        // Lanes
        let lane = [14.0, 50, 86, 128]
        let names = ["02 SPEECH", "03 FORMAT", "04 SUMMARY", "   LAYERS"]
        for i in 0..<4 {
            text(names[i], 0, lane[i] + 2, 10, ob.ink, bold: true)
            rule(x0, lane[i] + 18, x1, lane[i] + 18, ob.divider)
        }

        // 02 speech: each finished phrase, about every 5 seconds
        var t = 5.0 / 60
        while t <= minutes { rule(x(t), lane[0] + 4, x(t), lane[0] + 16, ob.ink.opacity(0.55), 0.6); t += 5.0 / 60 }
        text("a sentence every ~5 s", x(minutes) - 128, lane[0] - 12, 9)

        // 03 format: about every minute of steady speech (110 words)
        t = 0.8
        while t <= minutes { box(x(t) - 3, lane[1] + 4, 6, 12, ob.ink); t += 0.8 }
        text("110 new words (~50 s of talk), or 90 s", x(minutes) - 222, lane[1] - 12, 9)

        // 04 summary: a section every ~6.5 minutes, summed up as it closes; the last part waits for Stop
        let ends = [6.5, 13, 19.5, 26]
        var from = 0.0
        for (i, end) in ends.enumerated() {
            box(x(from) + 1, lane[2] + 4, x(end) - x(from) - 2, 12, ob.subtle, stroke: ob.divider)
            text("§\(i + 1)", x(from) + 5, lane[2] + 3, 9, ob.ink)
            box(x(end) - 4, lane[2] + 6, 8, 8, ob.ink)
            from = end
        }
        box(x(from) + 1, lane[2] + 4, x(minutes) - x(from) - 2, 12, ob.subtle.opacity(0.6), stroke: ob.divider.opacity(0.6))
        text("§5", x(from) + 5, lane[2] + 3, 9)
        text("~\(NotesSummary.sectionChars.formatted()) characters each", x(minutes) - 168, lane[2] - 12, 9)

        // Layers: the four summaries fold into one, then the final summary at Stop
        box(x(0) + 1, lane[3] + 4, x(26) - x(0) - 2, 12, ob.ink.opacity(0.18), stroke: ob.ink.opacity(0.18))
        text("§1–4 folded into one (\(NotesSummary.mergeCount) summaries → 1)", x(0) + 6, lane[3] + 3, 9, ob.ink)
        box(x(26) - 4, lane[3] + 6, 8, 8, ob.ink)
        box(x(minutes) - 6, lane[3] + 2, 12, 16, ob.accent)
        text("FINAL AT STOP", x(minutes) - 84, lane[3] + 22, 9, ob.accent, bold: true)
        text("main idea · 3 bullets · ≤ 3 paragraphs", x(minutes) - 216, lane[3] + 34, 9, ob.accent)

        // Time axis
        let axisY = h - 18
        rule(x0, axisY, x1, axisY, ob.ink)
        for m in stride(from: 0, through: Int(minutes), by: 5) {
            rule(x(Double(m)), axisY, x(Double(m)), axisY + 4, ob.ink)
            let last = m == Int(minutes)
            text(last ? "30 MIN · STOP" : "\(m)", last ? x(Double(m)) - 76 : x(Double(m)) - 3, axisY + 4, 9)
        }
    }
}
