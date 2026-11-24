import Foundation
import Testing

@testable import Core

private let page = ".kelp/artifacts/home/canvas.json"

@Test func notesFromBeforeMarksHadNumbersReadAsDrafts() throws {
    let old =
        Data(#"[{"board":"boards/A.html","target":"h1","text":"Hi","note":"bigger"},"#.utf8)
        + Data(#"{"board":"","target":"","text":"a quote","note":""}]"#.utf8)
    let marks = ArtifactMarks.read(old)
    #expect(marks.marks.map(\.id) == [1, 2] && marks.next == 3)
    #expect(marks.marks.map(\.kind) == [.element, .quote] && marks.marks.allSatisfy { $0.state == .draft })
    #expect(ArtifactMarks.read(Data("not json".utf8)) == ArtifactMarks() && ArtifactMarks.read(nil) == ArtifactMarks())
    let saved = ArtifactMarks.read(try marks.encoded())
    #expect(saved == marks)
}

/// A notes.json that doesn't read is never written over: a change to it fails and the file stays as it was.
@Test func marksThatDontReadAreNotWrittenOver() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(ArtifactMarks.file),
        odd = Data(#"{"marks": [{"id": 1, "kind": "x"}]}"#.utf8)
    try odd.write(to: file)
    #expect(throws: (any Error).self) {
        try ArtifactMarks.update(in: folder) {
            $0.next += 1
            return true
        }
    }
    #expect(FileManager.default.contents(atPath: file.path) == odd)
}

@Test func aMarkGoesFromDraftToTheAgentToTheUserAndBack() {
    var m = ArtifactMarks()
    m.apply(.drafts([ArtifactMark(board: "boards/A.html", target: "[data-id=title]", note: "bigger")]))
    #expect(m.marks.map(\.id) == [1])
    m.apply(.edit(HandEdit(board: "boards/A.html", id: "cta", what: "text", from: "Start", to: "Go")))
    let r1 = m.apply(.send(ids: [1], to: "s1", before: 4), now: 100)
    #expect(r1)
    #expect(m.marks[0].state == .sent && m.marks[0].note.isEmpty && m.edits.isEmpty)
    #expect(m.marks[0].rounds == [.init(note: "bigger", at: 100, to: "s1", before: 4)])
    // A window that still held the draft doesn't bring it back.
    let r2 = m.apply(.drafts([ArtifactMark(id: 1, note: "bigger")]))
    #expect(!r2)
    let r3 = m.apply(.reply(id: 1, text: "Done, at h1"))
    #expect(r3)
    // Pointed again while with the agent: the mark follows the element, its rounds as they were.
    let moved = m.apply(.retarget(id: 1, to: ArtifactMark(board: "boards/B.html", target: "[data-id=t2]", text: "Hi")))
    #expect(moved && m.marks[0].target == "[data-id=t2]" && m.marks[0].board == "boards/B.html")
    #expect(m.marks[0].state == .sent && m.marks[0].rounds.count == 1)
    let r4 = m.apply(.done(id: 7))
    #expect(!r4, "no such mark")
    let r5 = m.apply(.again(id: 1))
    #expect(!r5, "still with the agent")
    m.turnEnded(session: "s1", prompt: "Marks on \(page) (version 4)…", page: page, after: 5) { _, _ in .changed }
    #expect(m.marks[0].state == .check && m.marks[0].rounds[0].after == 5 && m.marks[0].rounds[0].outcome == .changed)
    let r6 = m.apply(.again(id: 1))
    #expect(r6 && m.marks[0].state == .draft)
    // Sent again, it keeps its number and what was said the first time.
    m.apply(.drafts([ArtifactMark(id: 1, board: "boards/A.html", target: "[data-id=title]", note: "even bigger")]))
    #expect(m.marks.count == 1 && m.marks[0].rounds.first?.reply == "Done, at h1")
    m.apply(.send(ids: [1], to: "s1", before: 5), now: 200)
    m.turnEnded(session: "s1", prompt: "Marks on \(page)", page: page, after: 6) { _, _ in .same }
    let r7 = m.apply(.done(id: 1))
    #expect(r7 && m.marks[0].state == .done && m.marks[0].rounds.count == 2)
    m.apply(.drafts([ArtifactMark(note: "new")]))
    #expect(m.marks.map(\.id) == [1, 2], "a new draft takes the next number")
}

@Test func onlyTheTurnThatGotTheMarksHandsThemBack() {
    var m = ArtifactMarks()
    m.apply(.drafts([ArtifactMark(note: "a"), ArtifactMark(note: "b")]))
    m.apply(.send(ids: [1], to: "s1", before: 1))
    m.apply(.send(ids: [2], to: "s2", before: 1))
    let check = { (m: ArtifactMarks) in m.marks.filter { $0.state == .check }.map(\.id) }
    let r8 = m.turnEnded(session: "s1", prompt: "fix the tests", page: page, after: 2) { _, _ in .changed }
    #expect(!r8)
    let other = "Marks on .kelp/artifacts/other/canvas.json"
    let r9 = m.turnEnded(session: "s1", prompt: other, page: page, after: 2) { _, _ in .changed }
    #expect(!r9)
    m.turnEnded(session: "s1", prompt: "Marks on \(page)", page: page, after: 2) { _, _ in .changed }
    #expect(check(m) == [1], "the other chat still has #2")
}

@Test func handEditsKeepWhatTheAgentLastSaw() {
    var m = ArtifactMarks()
    m.apply(.edit(HandEdit(board: "b", id: "t", what: "font-size", from: "h2", to: "h1")))
    m.apply(.edit(HandEdit(board: "b", id: "t", what: "font-size", from: "h1", to: "small")))
    #expect(m.edits == [HandEdit(board: "b", id: "t", what: "font-size", from: "h2", to: "small")])
    m.apply(.edit(HandEdit(board: "b", id: "t", what: "font-size", from: "small", to: "h2")))
    #expect(m.edits.isEmpty, "put back as it was")
}

@Test func aTurnsOutcomeIsWhatItDidToTheMarkedThing() {
    let before = #"<div data-id="card"><h2 data-id="title">Hi</h2><div><p>a</p></div></div><p data-id="x">x</p>"#
    let element = ArtifactMark(target: "[data-id=card]")
    let area = ArtifactMark(kind: .area, board: "boards/A.html", area: [0, 0, 10, 10])
    let rows: [(ArtifactMark, String?, ArtifactMark.Outcome)] = [
        (element, before.replacingOccurrences(of: ">x<", with: ">y<"), .same),
        (element, before.replacingOccurrences(of: "<p>a</p>", with: "<p>b</p>"), .changed),
        (element, #"<p data-id="x">x</p>"#, .gone),
        (area, before, .same),
        (area, before + " ", .changed),
        (area, nil, .gone)
    ]
    for (mark, after, expected) in rows {
        #expect(ArtifactMarks.outcome(of: mark, before: before, after: after) == expected)
    }
    #expect(
        BoardEdit.element(before, id: "card")
            == #"<div data-id="card"><h2 data-id="title">Hi</h2><div><p>a</p></div></div>"#)
    #expect(BoardEdit.element(#"<img data-id="i" src="a.png"><p>"#, id: "i") == #"<img data-id="i" src="a.png">"#)
    #expect(BoardEdit.element(#"<div data-id="open"><div></div>"#, id: "open") == nil)
}

@Test func marksGoToTheAgentAsNumberedLines() {
    let marks = [
        ArtifactMark(
            id: 1, board: "boards/A.html", target: "[data-id=title]", text: "Welcome", note: "bigger"),
        ArtifactMark(
            id: 2, kind: .area, board: "boards/A.html", area: [321.4, 63, 223, 185], picture: "marks/2.png",
            note: "a real screen"),
        ArtifactMark(
            id: 3, kind: .pen, board: "boards/B.html", target: "[data-id=cta]", picture: "marks/3.png", note: "",
            rounds: [.init(note: "a link here", at: 0, reply: "Linked to /login")]),
        ArtifactMark(id: 4, kind: .quote, text: "by December", note: "say the date"),
        ArtifactMark(
            id: 5, board: "motion.html", target: "[data-id=logo]", picture: "marks/5.png", time: 4.6,
            note: "later"),
        ArtifactMark(id: 6, kind: .area, board: "motion.html", note: "livelier music"),
        ArtifactMark(
            id: 7, kind: .area, board: "motion.html", text: "closer", area: [250, 168, 0, 0], time: 1.2, note: ""),
        ArtifactMark(
            id: 8, kind: .element, board: "boards/A.html", target: "[data-id=hero]", note: "like this",
            asked: "Screenshot or drawing?", reference: "marks/8-ref.png"),
        ArtifactMark(
            id: 9, kind: .element, board: "boards/A.html", target: "[data-id=c1]", note: "softer", like: ".card"),
        {
            var m = ArtifactMark(id: 10, kind: .element, board: "boards/A.html", target: "[data-id=t]", note: "cut off")
            m.inState = "error"
            m.width = 390
            m.language = "longer"
            return m
        }()
    ]
    let edits = [
        HandEdit(board: "boards/A.html", id: "cta", what: "text", from: "Start", to: "Go"),
        HandEdit(board: "boards/A.html", id: "sub", what: "font-size", from: nil, to: "small")
    ]
    #expect(
        ArtifactMarks.message(marks, edits: edits, page: page, name: "home", version: 5) == """
            Marks on .kelp/artifacts/home/canvas.json (version 5). Change only what each mark points at; \
            if you can't or won't, say why with `kelp artifact reply home <#> "…"`.
            #1 boards/A.html [data-id=title] «Welcome»: bigger
            #2 boards/A.html area 321,63,223,185 (picture: .kelp/artifacts/home/marks/2.png): a real screen
            #3 again boards/B.html pen near [data-id=cta] (picture: .kelp/artifacts/home/marks/3.png): look at this
              (before: «a link here»; you said «Linked to /login»)
            #4 «by December»: say the date
            #5 motion.html [data-id=logo] at 4.60 s (picture: .kelp/artifacts/home/marks/5.png): later
            #6 motion.html the whole page: livelier music
            #7 motion.html area 250,168,0,0 labelled «closer» at 1.20 s: look at this
            #8 boards/A.html [data-id=hero] (you asked: «Screenshot or drawing?») (example: .kelp/artifacts/home/marks/8-ref.png): like this
            #9 boards/A.html .card (every element like it, on every board): softer
            #10 boards/A.html [data-id=t] in state «error» at 390px wide with its text 40% longer: cut off
            Edited by the user since version 5, keep these:
              boards/A.html [data-id=cta] text «Start» → «Go»
              boards/A.html [data-id=sub] font-size none → small
            """)
}
