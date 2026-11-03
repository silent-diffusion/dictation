import Foundation
import Testing
@testable import ObertonCore

// Ported from tests/Dictation.Tests/ExtendedNotesTests.cs so both apps hold Extended Notes to the same rules.

@Suite struct NoteSessionTests {
    @Test func piecesAreAppendedWithTheirTimeAndAnchorsFollowEdits() {
        let s = NoteSession()
        s.appendHeard("hello world", seconds: 1)
        s.appendHeard("second piece", seconds: 5)
        #expect(s.transcript == "hello world second piece")
        #expect(s.transcriptAnchors.map(\.offset) == [0, 12])
        s.set(.transcript, "NOTE " + s.transcript, source: nil)
        #expect(s.transcriptAnchors.map(\.offset) == [5, 17])
        #expect(s.secondsAt(.transcript, 18) == 5)
        #expect(s.secondsAt(.transcript, 7) == 1)
        #expect(s.heard == "hello world second piece")
    }

    @Test func anEditIsFoundAsOneChange() {
        #expect(NoteSession.change("abcdef", "abXYef") == (2, 2, 2))
        #expect(NoteSession.change("abc", "abc!") == (3, 0, 1))
        #expect(NoteSession.change("hello", "") == (0, 5, 0))
    }

    @Test func positionsMoveWithAnEdit() {
        #expect(NoteSession.move(3, 5, 2, 4) == 3)
        #expect(NoteSession.move(10, 5, 2, 4) == 12)
        #expect(NoteSession.move(6, 5, 2, 4) == 9)
        #expect(NoteSession.move(5, 5, 0, 3) == 5)
        #expect(NoteSession.moveAnchor(5, 5, 0, 3) == 8)
    }

    @Test func formattingTakesWhatIsNewAndAppendsTheAIOutput() {
        let s = NoteSession()
        s.appendHeard("so the plan is simple", seconds: 0)
        let take = s.beginFormat()!
        #expect(take.sent == "so the plan is simple")
        s.appendHeard("and then more", seconds: 30)
        s.endFormat(heard: take.heard, sent: take.sent, ai: "The plan is simple.", seconds: take.seconds, failed: false)
        #expect(s.formatted == "The plan is simple.")
        #expect(s.beginFormat()?.sent == "and then more")
    }

    @Test func anEditWhileTheAIWorksDoesntLoseTheBoundary() {
        let s = NoteSession()
        s.appendHeard("first part", seconds: 0)
        let take = s.beginFormat()!
        s.set(.transcript, "My note. " + s.transcript, source: nil)
        s.endFormat(heard: take.heard, sent: take.sent, ai: "First part.", seconds: take.seconds, failed: false)
        #expect(s.formattedThrough == s.transcript.utf16.count)
        #expect(s.unformattedWords() == 0)
    }

    @Test func sectionsAreTakenInOrderAndTheSummaryKeepsTheUsersEdit() {
        let s = NoteSession()
        s.appendHeard("words", seconds: 0)
        let take = s.beginFormat()!
        s.endFormat(heard: take.heard, sent: take.sent, ai: "Words.", seconds: 0, failed: false)
        let section = s.beginSection(maxChars: NotesSummary.inputBudget)!
        #expect(section.text == "Words.")
        s.endSection(nil, start: section.start, end: section.end)
        #expect(s.beginSection(maxChars: NotesSummary.inputBudget)?.text == "Words.")
        s.endSection("One word.", start: section.start, end: section.end)
        #expect(s.beginSection(maxChars: NotesSummary.inputBudget) == nil)
        #expect(s.frontier().count == 1)
        s.set(.summary, "Mine", source: nil)
        #expect(!s.endSummary("AI summary", basedOn: ""))
        #expect(s.summary == "Mine")
        #expect(s.endSummary("AI summary", basedOn: "Mine"))
        #expect(s.summaryByAi == "AI summary")
    }

    @Test func mergedDigestsLeaveTheFrontierAndCoverTheirParts() {
        let s = NoteSession()
        for i in 0..<4 {
            s.formatted += "Part \(i). "
            #expect(s.beginSection(maxChars: 8) != nil)
            s.endSection("D\(i)", start: Double(i * 60), end: Double((i + 1) * 60))
        }
        #expect(s.frontier().count == 4)
        let group = NotesSummary.mergeGroup(s.frontier())!
        s.merge(group, text: "D0-3")
        let left = s.frontier()
        #expect(left.count == 1)
        #expect(left[0].level == 1 && left[0].first == 0 && left[0].last == 3 && left[0].start == 0 && left[0].end == 240)
    }

    @Test func aPositionInTheFormattedTextMapsToItsShareOfTheStep() {
        let s = NoteSession()
        s.appendHeard("one two three four", seconds: 10)
        s.appendHeard("five six", seconds: 70)
        let take = s.beginFormat()!
        s.endFormat(heard: take.heard, sent: take.sent, ai: "One two three four five six.", seconds: take.seconds, failed: false)
        s.seconds = 130
        #expect(s.secondsAt(.formatted, 0) == 10)
        #expect((60...80).contains(s.secondsAt(.formatted, s.formatted.utf16.count / 2)))
    }

    @Test func aPartThatCarriesOnASentenceJoinsIt() {
        let s = NoteSession()
        for (heard, ai, t) in [("and so", "And so,", 0.0), ("we went home", "we went home.", 10), ("Next topic", "Next topic.", 20)] {
            s.appendHeard(heard, seconds: t)
            let take = s.beginFormat()!
            s.endFormat(heard: take.heard, sent: take.sent, ai: ai, seconds: take.seconds, failed: false)
        }
        #expect(s.formatted == "And so, we went home.\n\nNext topic.")
    }

    @Test func markersGoOnTheirOwnLineAndComeBackWhenTranscribedAgain() {
        let s = NoteSession()
        s.appendHeard("before", seconds: 0)
        s.addMarker(83)
        s.appendHeard("after", seconds: 90)
        #expect(s.transcript == "before\n⚑ 1:23\nafter")
        #expect(NoteSession.markerLabel(3723) == "1:02:03")
        s.replaceTranscript([(0, "again before"), (90, "again after")])
        #expect(s.transcript == "again before\n⚑ 1:23\nagain after")
        #expect(s.formatted.isEmpty)
    }

    @Test func aPartOfTheTranscriptEndsAtASentence() {
        let s = NoteSession()
        s.appendHeard("One two three.", seconds: 0)
        s.appendHeard("four five", seconds: 5)
        s.appendHeard("six seven eight nine ten", seconds: 10)
        let part = s.beginFormatPart(maxWords: 6)!
        #expect(part.sent == "One two three.")
        #expect(part.heard == "One two three.")
    }
}

@Suite struct NotesFormatTests {
    @Test func aReplyThatRunsOnPastTheTextIsCutBackToIt() {
        let sent = "We visited two families. We talked about the budget."
        let reply = "We visited two families. We talked about the budget.  \n\n⚠️ 00:03:15  \n⚠️ 00:03:16  \n⌋  \n⏸️  \n☑ 00:00:02\n璩  \n璩"
        #expect(NotesFormat.accept(sent: sent, reply: reply) == sent)
    }

    @Test func loopsAreCollapsedButASentenceSaidTwiceStays() {
        #expect(NotesFormat.collapseRepeats("Hello. Thank you. Thank you. Thank you. Thank you. Bye.") == "Hello. Thank you. Bye.")
        #expect(NotesFormat.collapseRepeats("Thank you. Thank you. Bye.") == "Thank you. Thank you. Bye.")
        #expect(NotesFormat.collapseRepeats("Thank you.\nThank you.\nThank you.") == "Thank you.\nThank you.\nThank you.")
    }

    @Test func aReplyThatAddsWordsOrChangesANumberIsRejected() {
        let sent = "it is north of lowes on 4th east and 1550 north at 3 on saturday"
        #expect(NotesFormat.accept(sent: sent, reply: "It is north of Lowe's, on 4th East and 155-0 North, at 3 on Saturday.") == nil)
        #expect(NotesFormat.accept(sent: sent, reply: "It is north of Lowe's on 4th East and 1550 North at 3 on Saturday, and everyone should bring a dish and a friend along to the event.") == nil)
        #expect(NotesFormat.accept(sent: sent, reply: "North.") == nil)
        #expect(NotesFormat.accept(sent: sent, reply: "It is north of Lowe's, on 4th East and 1550 North, at 3 on Saturday.")
            == "It is north of Lowe's, on 4th East and 1550 North, at 3 on Saturday.")
    }

    @Test func labelsNoOneSaidAndSplitLinesAreUndone() {
        #expect(NotesFormat.accept(sent: "you need to go on the state in volleyball", reply: "⚠️ listener note: You need to go on the state in volleyball.")
            == "You need to go on the state in volleyball.")
        #expect(NotesFormat.accept(sent: "thank you what are you going to think about it", reply: "Thank you.  \nWhat are you going to think about it?")
            == "Thank you. What are you going to think about it?")
        #expect(NotesFormat.accept(sent: "Todo: buy milk", reply: "Todo: buy milk") == "Todo: buy milk")
    }

    @Test func markersStayLostOnesComeBackAndMadeUpOnesGo() {
        let sent = "Hello there.\n⚑ 1:23\nMore words here."
        #expect(NotesFormat.accept(sent: sent, reply: sent) == sent)
        #expect(NotesFormat.accept(sent: sent, reply: "Hello there.\nMore words here.") == "Hello there.\nMore words here.\n⚑ 1:23")
        #expect(NotesFormat.accept(sent: sent, reply: "Hello there.\n⚑ 1:23\n⚑ 9:59\nMore words here.") == sent)
    }

    @Test func theReplyLimitFollowsTheText() {
        #expect((240...260).contains(NotesFormat.maxTokens(String(repeating: "a", count: 600))))
        #expect((640...660).contains(NotesFormat.maxTokens(String(repeating: "会", count: 600))))
    }

    @Test func markersAreOnlyMentionedWhenTheTextHasThem() {
        #expect(!NotesFormat.instructions("plain words").contains("⚑"))
        #expect(NotesFormat.instructions("words\n⚑ 1:00").contains("⚑"))
    }
}

@Suite struct NotesSummaryTests {
    @Test func aSectionEndsAtAParagraphOrSentenceWithinTheBudget() {
        let text = "First sentence here.\nSecond one here. Third one is longer than the rest of them."
        #expect(NotesSummary.sectionEnd(text, from: 0, maxChars: 500) == text.utf16.count)
        #expect(NotesSummary.sectionEnd(text, from: 0, maxChars: 30) == 21)
        #expect(NotesSummary.sectionEnd(text, from: 0, maxChars: 45) == 37)
    }

    @Test func theSummaryIsShapedIntoMainIdeaPointsAndParagraphs() {
        let raw = "**Summary**\nMain idea: The launch moves to May.\n\n- Budget approved\n- Hiring paused\n- QA needs two weeks\n- Extra point\n\n" +
            "First para.\n\nSecond para.\n\nThird para.\n\nFourth para."
        let shaped = NotesSummary.shape(raw)!
        #expect(shaped.hasPrefix("Main idea: The launch moves to May."))
        #expect(shaped.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count == 3)
        #expect(!shaped.contains("Extra point"))
        #expect(!shaped.contains("**"))
        #expect(shaped.hasSuffix("Third para. Fourth para."))
        #expect(shaped.components(separatedBy: "\n\n").count == 5)
        let plain = NotesSummary.shape("The team met about the launch. Dates were discussed at length.\n\nBudget is fine.")!
        #expect(plain.hasPrefix("Main idea: The team met about the launch."))
        #expect(plain.contains("Dates were discussed at length."))
        #expect(NotesSummary.shape("...") == nil)
    }

    @Test func aLabelledSummaryParagraphLosesItsLabel() {
        #expect(NotesSummary.shape("Main idea: Plans.\n\n- A\n- B\n- C\n\nWhat was decided: We meet weekly outside the library.")!
            .hasSuffix("\n\nWe meet weekly outside the library."))
    }

    @Test func fourDigestsOfALevelMergeAndAnOversizedFrontierMergesItsOldest() {
        func d(_ n: Int, _ level: Int, _ chars: Int) -> NoteDigest {
            NoteDigest(level: level, first: n, last: n, start: 0, end: 0, text: String(repeating: "x", count: chars))
        }
        #expect(NotesSummary.mergeGroup([d(0, 0, 100), d(1, 0, 100), d(2, 0, 100)]) == nil)
        let four = [d(0, 0, 100), d(1, 0, 100), d(2, 0, 100), d(3, 0, 100)]
        #expect(NotesSummary.mergeGroup(four) == four)
        let mixed = [d(0, 1, 100), d(1, 0, 100), d(2, 0, 100), d(3, 0, 100), d(4, 0, 100)]
        #expect(NotesSummary.mergeGroup(mixed) == Array(mixed.dropFirst()))
        let big = [d(0, 1, NotesSummary.frontierBudget / 2), d(1, 2, NotesSummary.frontierBudget / 2), d(2, 0, 100)]
        #expect(NotesSummary.mergeGroup(big) == Array(big.prefix(2)))
    }

    @Test func aUsableDigestHasWordsAndIsShorterThanItsSource() {
        let source = Array(repeating: "word", count: 200).joined(separator: " ")
        #expect(NotesSummary.isUsable(input: source, output: "A short summary of it all."))
        #expect(!NotesSummary.isUsable(input: source, output: "..."))
        #expect(!NotesSummary.isUsable(input: source, output: source + " and more"))
        #expect(NotesSummary.inputBudget > 6000)
    }
}

@Suite struct NotesEditsTests {
    static func formatted(_ heard: String, _ user: String, _ ai: String) -> NoteSession {
        let s = NoteSession()
        s.appendHeard(heard, seconds: 0)
        if user != heard { s.set(.transcript, user, source: nil) }
        let t = s.beginFormat()!
        s.endFormat(heard: t.heard, sent: t.sent, ai: ai, seconds: t.seconds, failed: false)
        return s
    }

    static func show(_ pieces: [EditPiece]) -> String {
        pieces.map { p in
            switch p.mark {
            case .plain: p.text
            case .paragraph: "|"
            case .aiRemoved: "-" + p.text
            case .aiAdded: "+" + p.text
            case .aiParagraph: "¶"
            case .userRemoved: "u-" + p.text
            case .userChanged: "u~" + p.text
            case .userNote: "u+" + p.text
            }
        }.joined(separator: " ")
    }

    @Test func theAIAndTheUserAreMarkedApart() {
        let s = Self.formatted("um the overton release is ready", "um the Oberton release is ready", "The Oberton release is ready.")
        s.set(.formatted, s.formatted + "\n\nCheck the date", source: nil)
        #expect(Self.show(NotesEdits.build(s)) == "-um The u-overton u~Oberton release is ready. | u+Check u+the u+date")
    }

    @Test func aParagraphTheAIMadeIsMarked() {
        let s = Self.formatted("first point second point", "first point second point", "First point.\n\nSecond point.")
        #expect(Self.show(NotesEdits.build(s)) == "First point. ¶ Second point.")
    }

    @Test func aNoteTypedIntoTheTranscriptIsANoteAndTheTailIsShownToo() {
        let s = Self.formatted("hello there", "hello there", "Hello there.")
        s.appendHeard("next part here", seconds: 10)
        s.set(.transcript, s.transcript + "\nmy note", source: nil)
        #expect(Self.show(NotesEdits.build(s)) == "Hello there. | next part here | u+my u+note")
    }

    @Test func wordsTheUserRemovedFromTheFormattedText() {
        let s = Self.formatted("we said this and that", "we said this and that", "We said this and that.")
        s.set(.formatted, "We said this.", source: nil)
        #expect(Self.show(NotesEdits.build(s)) == "We said this u-and u-that.")
    }

    @Test func notesTypedBeforeTheSessionAreTheUsersOwn() {
        let s = NoteSession()
        s.set(.transcript, "Agenda: budget\n", source: nil)
        s.appendHeard("so the budget is final", seconds: 2)
        #expect(s.transcript == "Agenda: budget\nso the budget is final")
        #expect(Self.show(NotesEdits.build(s)) == "u+Agenda: u+budget | so the budget is final")
        let t = s.beginFormat()!
        #expect(t.heard == "so the budget is final")
        s.endFormat(heard: t.heard, sent: t.sent, ai: t.sent, seconds: t.seconds, failed: false)
        #expect(Self.show(NotesEdits.build(s)) == "u+Agenda: u+budget | so the budget is final")
    }

    @Test func longDiffCopesWithTenThousandWordsAndFewEdits() {
        var rng = SystemRandomNumberGenerator()
        let words = (0..<10_000).map { _ in "w\(Int.random(in: 0..<500, using: &rng))" }
        var edited = words
        for k in 0..<40 { edited[Int.random(in: 0..<edited.count, using: &rng)] = "CHANGED\(k)" }
        edited.insert("inserted", at: 5000)
        edited.remove(at: 100)
        let d = LongDiff.compute(words, edited)
        #expect(d.filter { $0.kind != .removed }.map(\.word) == edited)
        #expect((2...90).contains(d.filter { $0.kind != .same }.count))
    }
}

@Suite struct NotesStoreTests {
    @Test func theDraftGoesToTheNextSessionOnce() {
        let store = NotesStore(dir: nil)
        store.setDraft("Agenda: budget")
        #expect(store.draft == "Agenda: budget")
        #expect(store.takeDraft() == "Agenda: budget")
        #expect(store.draft.isEmpty)
        #expect(store.takeDraft().isEmpty)
    }

    @Test func sessionsAreSavedInTheirOwnFolderAndLoadedAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-notes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(dir: dir)
        let s = try store.create(source: .mic)
        s.appendHeard("hello there", seconds: 1)
        s.addMarker(2)
        store.saveNow(s)
        #expect(FileManager.default.fileExists(atPath: s.folder!.appending(path: "session.json").path))
        let again = NotesStore(dir: dir)
        #expect(again.sessions.count == 1)
        #expect(again.sessions[0].transcript == s.transcript)
        #expect(again.sessions[0].finished) // left open: closed when loaded
        #expect(again.sessions[0].markers.count == 1)
    }

    @Test func aFinishedSessionIsCountedOnItsDayApartFromDictation() {
        let usage = NotesUsage(url: nil)
        let s = NoteSession()
        s.source = .both
        s.seconds = 600
        s.appendHeard("one two three", seconds: 0)
        s.set(.transcript, s.transcript + " my note", source: nil)
        usage.record(s, formatRequests: 3, summaryRequests: 2)
        let t = usage.totals(days: 30)
        #expect(t.sessions == 1 && t.seconds == 600 && t.wordsHeard == 3 && t.wordsTyped == 2 && t.aiRequests == 5)
        #expect(t.sources["Both"] == 1)
        #expect(NotesUsage.hoursMinutes(3725) == "1:02")
    }

    @Test func figuresFollowTheFinishedSessions() {
        let a = NoteSession(), b = NoteSession(), live = NoteSession()
        a.finished = true; a.seconds = 120; a.appendHeard("one two", seconds: 0); a.addMarker(10)
        b.finished = true; b.seconds = 600; b.source = .computer
        b.chunks = [NoteChunk(heard: "", sent: "", ai: "", seconds: 0, aiFailed: false), NoteChunk(heard: "", sent: "", ai: "", seconds: 0, aiFailed: true)]
        let f = NotesFigures.compute([a, b, live], from: nil)
        #expect(f.sessions == 2 && f.seconds == 720 && f.markers == 1 && f.steps == 2 && f.stepsKept == 1)
        #expect(f.longest.first === b)
        #expect(f.sources[.computer]?.sessions == 1)
    }
}

@Suite struct NotesExportTests {
    static func session() -> NoteSession {
        let s = NoteSession()
        s.title = "Product sync"; s.summary = "Ship Monday."; s.formatted = "We ship on Monday."; s.transcript = "we ship on monday"; s.seconds = 3725
        return s
    }

    @Test func everythingAsMarkdownHasTheTitleAndEachPart() {
        let md = NotesExport.build(Self.session(), part: .everything, markdown: true)
        #expect(md.hasPrefix("# Product sync"))
        #expect(md.contains("1:02:05"))
        #expect(md.range(of: "## Summary")!.lowerBound < md.range(of: "## Formatted")!.lowerBound)
        #expect(md.contains("we ship on monday"))
        #expect(!NotesExport.build(Self.session(), part: .transcript, markdown: false).contains("Ship Monday."))
    }

    @Test func theWordDocumentIsAZipWithItsParts() {
        let d = NotesExport.buildDocx(Self.session(), part: .everything)
        #expect(d.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        let text = String(decoding: d, as: UTF8.self)
        #expect(text.contains("word/document.xml") && text.contains("Heading1") && text.contains("We ship on Monday."))
        #expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite struct NotesAudioTests {
    @Test func quietSpeechIsBroughtUpAndItsPausesFound() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "oberton-notes-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appending(path: "audio.wav")
        let rate = 16_000
        let w = try WavWriter(url: src)
        w.write((0..<(rate * 4)).map { i in
            let t = Double(i) / Double(rate)
            return Float(t < 1 || t >= 3 ? 0.02 * sin(2 * .pi * 220 * t) : 0.0002 * sin(2 * .pi * 50 * t))
        })
        w.close()
        let prepared = try NotesAudio.prepare(src, to: dir.appending(path: "play.wav"))
        #expect((30...34).contains(prepared.gainDb))
        #expect((3.99...4.01).contains(prepared.seconds))
        #expect(prepared.silences.count == 1)
        #expect((0.9...1.2).contains(prepared.silences[0].start) && (2.8...3.1).contains(prepared.silences[0].end))
        #expect(prepared.silence(at: 2) != nil && prepared.silence(at: 0.5) == nil)
    }

    @Test func gainNeverLowersAndNeverExceedsTheCap() {
        #expect(NotesAudio.gain([0.95, 0.95]) == 1)
        #expect(abs(NotesAudio.gain([0.00001, 0.001]) - Float(pow(10, 40.0 / 20))) < 0.01)
    }

    @Test func micAlonePassesThroughAndComputerAudioIsAddedToIt() {
        let m = NotesMixer()
        #expect(m.mix(withMic: [0.1, -0.2, 0]) == [0.1, -0.2, 0])
        m.addComputer([0.5, 0.5])
        #expect(m.mix(withMic: [0.1, 0.1, 0.1]) == [0.6, 0.6, 0.1])
        m.addComputer([2])
        #expect(m.mix(withMic: [0.5]) == [1])
    }
}

@Suite struct NotesModelTests {
    let models = [NotesModels.Installed(name: "llama3.2:3b", bytes: 2_000_000_000, billions: 3.2),
                  NotesModels.Installed(name: "qwen3:14b", bytes: 9_000_000_000, billions: 14.8),
                  NotesModels.Installed(name: "nomic-embed-text", bytes: 300_000_000, billions: 0.1),
                  NotesModels.Installed(name: "gpt-oss:120b-cloud", bytes: 400, billions: 120)]

    @Test func theBestIsTheLargestThatFits() {
        #expect(NotesModels.pickBest(models, gpuBytes: 12_000_000_000)?.name == "qwen3:14b")
        #expect(NotesModels.pickBest(models, gpuBytes: 4_000_000_000)?.name == "llama3.2:3b")
        #expect(NotesModels.pickBest(models, gpuBytes: 1_000)?.name == "llama3.2:3b") // nothing fits: the smallest
    }

    @Test func theSettingIsResolved() {
        #expect(NotesModels.resolve("", activeModel: .appleOnDevice, installed: [], gpuBytes: nil).model == .appleOnDevice)
        #expect(NotesModels.resolve("active", activeModel: .appleOnDevice, installed: models, gpuBytes: nil).model == .appleOnDevice)
        #expect(NotesModels.resolve("ollama:llama3.2:3b", activeModel: .appleOnDevice, installed: models, gpuBytes: nil).model.name == "llama3.2:3b")
        #expect(NotesModels.resolve("ollama:gone", activeModel: .appleOnDevice, installed: models, gpuBytes: 12_000_000_000).model.name == "qwen3:14b")
    }
}
