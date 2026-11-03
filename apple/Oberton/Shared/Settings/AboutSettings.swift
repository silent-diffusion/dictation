import ObertonCore
import SwiftUI

struct AboutSection: View {
    @Environment(\.ob) private var ob

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        VStack(alignment: .leading, spacing: 0) {
            Text("Oberton \(version) for \(Device.noun)").font(Ob.mono(13, .bold))
            Caption("Local, private dictation and read aloud.").padding(.top, 4)
            Hairline().padding(.vertical, 16)
            part("D.2.1", "What it is", "概要",
                 "The name is German for overtone: the AI adds a layer of polish on top of your own voice. You speak, Oberton writes it down and tidies it up, and the text goes where your cursor was.")
            part("D.2.2", "How it works", "口述", nil) {
                steps([("01 Listen", "The microphone, while you hold the floor."), ("02 Transcribe", "Apple Speech, on this \(Device.noun)."),
                       ("03 Tidy up", "Your profile's AI: Apple Intelligence by default."), ("04 Insert", Device.noun == "Mac" ? "Pasted at the cursor." : "Copied, ready to paste.")])
            }
            part("D.2.3", "How Extended Notes works", "記録",
                 "A session runs four steps side by side, each on its own rhythm, so the text keeps up with a lecture of any length while the AI only ever reads as much as fits in its memory at once.") {
                notesSteps
            }
            part("D.2.4", "What it keeps", "履歴", nil) {
                VStack(alignment: .leading, spacing: 0) {
                    keep("History", "Your recent dictations: what was heard, the AI's edit, what went in, and the app.")
                    keep("Daily counts", "Numbers only: words, dictations, turnaround. Never text.")
                    keep("Extended notes", "Each session's texts and recording (about 115 MB an hour) in its own folder, and its daily counts apart from dictation's.")
                    keep("Settings", "Profiles and settings. API keys are in the Keychain.")
                }
            }
            part("D.2.5", "Design language", "計器",
                 "Oberton is drawn like a printed instrument panel: black ink on gray paper, 1px lines, capitalized monospaced labels and readouts, rings of dots for numbers. Dark mode is the same sheet inverted. Color is a signal: the accent marks what is live or matters most, and red means the microphone is recording, nowhere else.") {
                glossary
            }
        }
    }

    private func part<Extra: View>(_ address: String, _ title: String, _ jp: String, _ body: String?, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Readout(address).frame(width: 64, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(title.uppercased()).font(Ob.mono(12, .bold))
                        Spacer()
                        Decor(jp)
                    }
                    if let body { Text(body).font(Ob.sans(14)).lineSpacing(8).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true) }
                    extra()
                }
            }
            Hairline().padding(.vertical, 16)
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

    private var glossary: some View {
        let words: [(String, String, String, String)] = [
            ("倍音", "baion", "overtone", "Sidebar, About"), ("計器", "keiki", "instrument", "Dashboard"),
            ("口述", "kōjutsu", "dictation", "Speech to text"), ("読上", "yomiage", "reading aloud", "Read aloud"),
            ("履歴", "rireki", "history", "History"), ("設定", "settei", "settings", "Settings"), ("概要", "gaiyō", "overview", "This page"),
            ("録音", "rokuon", "recording", "Overlay while recording"), ("処理中", "shorichū", "processing", "Overlay while processing"),
            ("挿入", "sōnyū", "insertion", "Overlay after inserting"), ("記録", "kiroku", "record", "Notepad"),
        ]
        return VStack(spacing: 0) {
            HStack { Readout("Word").frame(width: 70, alignment: .leading); Readout("Reading").frame(width: 90, alignment: .leading)
                Readout("English").frame(width: 120, alignment: .leading); Readout("Where you see it"); Spacer() }
                .padding(.vertical, 6)
            ForEach(words, id: \.0) { w in
                Hairline()
                HStack {
                    Text(w.0).font(Ob.jp(16, .bold)).frame(width: 70, alignment: .leading)
                    Text(w.1).font(Ob.sans(13).italic()).foregroundStyle(ob.muted).frame(width: 90, alignment: .leading)
                    Text(w.2).font(Ob.mono(12)).frame(width: 120, alignment: .leading)
                    Readout(w.3)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.top, 8)
    }
}
