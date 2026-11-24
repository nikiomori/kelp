import AVFoundation
import Foundation
import Testing

@testable import Core

private let board = """
    <section class="screen" data-id="welcome">
      <h1 class="title" data-id="title">Welcome &amp; hello</h1>
      <p>Open a folder.</p>
      <p>Open a folder.</p>
      <button class="button" data-id="start" style="padding: 8px; gap: 4px">Start</button>
      <div data-id="card"><span>inside</span></div>
    </section>
    """

@Test func textTypedOnABoardReplacesOnlyThatElements() throws {
    let out = try #require(BoardEdit.setText(board, id: "title", old: "Welcome & hello", new: "Hi <you>"))
    #expect(out.contains(#"data-id="title">Hi &lt;you&gt;</h1>"#))
    #expect(out.replacingOccurrences(of: "Hi &lt;you&gt;", with: "Welcome &amp; hello") == board)
    #expect(BoardEdit.setText(board, id: "title", old: "Something else", new: "x") == nil, "the file changed since")
    #expect(BoardEdit.setText(board, id: "card", old: "inside", new: "x") == nil, "not an element of text alone")
    #expect(BoardEdit.setText(board, id: nil, old: "Open a folder.", new: "x") == nil, "twice: which one?")
    #expect(BoardEdit.setText(board, id: nil, old: "Start", new: "Go")?.contains(">Go</button>") == true)
}

@Test func aStyleSetOnABoardGoesIntoItsElementsStyle() throws {
    let added = try #require(BoardEdit.setStyle(board, id: "title", property: "color", value: "var(--accent)"))
    #expect(added.contains(#"<h1 class="title" data-id="title" style="color: var(--accent)">"#))
    let changed = try #require(BoardEdit.setStyle(board, id: "start", property: "padding", value: "var(--space-4)"))
    #expect(changed.contains(#"style="gap: 4px; padding: var(--space-4)">Start"#))
    let removed = try #require(BoardEdit.setStyle(board, id: "start", property: "gap", value: nil))
    #expect(removed.contains(#"data-id="start" style="padding: 8px">"#))
    #expect(BoardEdit.setStyle(board, id: "start", property: "color", value: "red\"><script>") == nil)
    #expect(BoardEdit.setStyle(board, id: "nope", property: "color", value: "red") == nil)
    #expect(
        DesignSystem.names(tokens: ##"{"color": {"bg": "#fff", "accent": "#000"}, "space": {"4": "16px"}}"##)
            == ["color": ["accent", "bg"], "space": ["4"]])
}

@Test func aSceneTimeIsSetOnItsElement() throws {
    let page = #"<div class="scene" data-id="intro" data-start="0" data-duration="2"><h1 data-id="t">Hi</h1></div>"#
    let moved = try #require(BoardEdit.setAttribute(page, id: "intro", name: "data-start", value: "0.5"))
    #expect(moved.contains(#"data-start="0.5" data-duration="2""#))
    let added = try #require(BoardEdit.setAttribute(page, id: "t", name: "data-start", value: "1"))
    #expect(added.contains(#"<h1 data-id="t" data-start="1">"#))
    #expect(BoardEdit.setAttribute(page, id: "intro", name: "style", value: "x") == nil, "only data- attributes")
    #expect(BoardEdit.setAttribute(page, id: "intro", name: "data-start", value: "1\"><script>") == nil)
    // A link's address and a picture's words take any text, escaped, and read back as typed.
    let link = ##"<a data-id="cta" href="#">Go</a>"##
    let linked = try #require(BoardEdit.setAttribute(link, id: "cta", name: "href", value: "/a?x=1&y=\"2\""))
    #expect(linked.contains(#"href="/a?x=1&amp;y=&quot;2&quot;""#))
    #expect(BoardEdit.attribute(linked, id: "cta", name: "href") == "/a?x=1&y=\"2\"")
}

/// An element taken out leaves no empty line; one copied comes right after it, its data-ids and those inside it
/// numbered so each stays one of a kind.
@Test func anElementIsTakenOutOrCopiedWhole() throws {
    let page = "<div data-id=\"a\">\n  <p data-id=\"t\">Hi <b>x</b></p>\n  <img data-id=\"i\" src=\"a.png\">\n</div>"
    #expect(BoardEdit.remove(page, id: "t") == "<div data-id=\"a\">\n  <img data-id=\"i\" src=\"a.png\">\n</div>")
    #expect(BoardEdit.remove(page, id: "i") == "<div data-id=\"a\">\n  <p data-id=\"t\">Hi <b>x</b></p>\n</div>")
    let copied = try #require(BoardEdit.duplicate(page, id: "t"))
    #expect(copied.id == "t-2")
    #expect(copied.text.contains("<p data-id=\"t\">Hi <b>x</b></p>\n  <p data-id=\"t-2\">Hi <b>x</b></p>"))
    let whole = try #require(BoardEdit.duplicate(copied.text, id: "a"))
    // t-2 is taken, so the whole copy takes the next number free for all its ids
    #expect(whole.id == "a-3" && whole.text.contains("data-id=\"t-2-3\"") && whole.text.contains("data-id=\"t-3\""))
    #expect(BoardEdit.setAttribute(page, id: "i", name: "src", value: "b.png")?.contains("src=\"b.png\"") == true)
    #expect(BoardEdit.remove(page, id: "none") == nil)
    let hidden = try #require(BoardEdit.setAttribute(page, id: "t", name: "data-hidden", value: "true"))
    #expect(BoardEdit.setAttribute(hidden, id: "t", name: "data-hidden", value: nil) == page)
    let stage = #"<body data-width="1920" data-height="1080"><p data-id="t">x</p></body>"#
    #expect(
        BoardEdit.setAttribute(stage, id: nil, name: "data-width", value: "1080")
            == #"<body data-width="1080" data-height="1080"><p data-id="t">x</p></body>"#)
}

/// An element without a data-id gets one, found as the nth of its tag in the page's body; the id is new.
@Test func anElementWithoutAnIDGetsOne() throws {
    let page = #"<html><head><style>p{}</style></head><body><p>a</p><P data-id="p-1">b</P><p>c</p></body></html>"#
    let given = try #require(BoardEdit.giveID(page, tag: "p", index: 2))
    #expect(given.id == "p-2")
    #expect(given.text.contains(#"<p data-id="p-2">c</p>"#))
    #expect(BoardEdit.giveID(page, tag: "p", index: 3) == nil)
    #expect(BoardEdit.giveID(given.text, tag: "p", index: 2)?.text == given.text, "one that has an id keeps it")
    #expect(BoardEdit.giveID(page, tag: "p\"", index: 0) == nil)
    #expect(BoardEdit.freeID(page, "p") == "p-2")
    // Counted as the page's DOM counts: not in a comment, a template or a script; the page's own new id is kept.
    let hidden = #"<body><!-- <p>old</p> --><template><p>t</p></template><script>"<p>"</script><p>a</p><p>b</p></body>"#
    #expect(
        BoardEdit.giveID(hidden, tag: "p", index: 1, named: "p-7")?.text.contains(#"<p data-id="p-7">b</p>"#) == true)
    #expect(BoardEdit.giveID(page, tag: "p", index: 0, named: "p-1")?.id == "p-2", "a taken name is not used twice")
    #expect(BoardEdit.appendToBody("<body><p>a</p></body>", "<img>") == "<body><p>a</p><img>\n</body>")
    #expect(BoardEdit.appendToBody("<p>a</p>", "<img>") == "<p>a</p><img>\n")
}

/// Words styled by hand go inside their element; only spans, b, i, u, strong, em and br with a style are taken.
@Test func styledWordsGoInsideTheirElement() {
    let page = #"<h1 data-id="t" class="big">Каждый день</h1>"#
    let html = #"<span style="color: var(--accent)">Каждый</span> <b>день</b>"#
    #expect(BoardEdit.setInner(page, id: "t", html: html) == #"<h1 data-id="t" class="big">"# + html + "</h1>")
    #expect(BoardEdit.setInner(page, id: "t", html: "<script>x()</script>") == nil)
    #expect(BoardEdit.setInner(page, id: "t", html: #"<span onclick="x()">a</span>"#) == nil)
    #expect(BoardEdit.setInner(page, id: "none", html: "a") == nil)
}

/// A font brought into a page is an @font-face in its first style, a new style before </head>, or one at a board's
/// start; a name that could end the rule is refused.
@Test func aFontIsBroughtIntoThePage() {
    let face = "@font-face { font-family: 'Grotesk'; src: url('G.woff2'); font-display: swap; }"
    #expect(
        BoardEdit.addFontFace("<style>h1{}</style><p>", family: "Grotesk", file: "G.woff2") == "<style>h1{}" + face
            + "\n</style><p>")
    #expect(
        BoardEdit.addFontFace("<head></head>", family: "Grotesk", file: "G.woff2")
            == "<head><style>\(face)</style>\n</head>")
    #expect(BoardEdit.addFontFace("<p>a</p>", family: "Grotesk", file: "G.woff2") == "<style>\(face)</style>\n<p>a</p>")
    #expect(BoardEdit.addFontFace("<p>", family: "x'); }", file: "G.woff2") == nil)
}

/// A 16:9 stage made 9:16: fitted, its content is framed at its design size and scaled into the middle; filled, it
/// covers the stage, cropped at the sides; changed again, the same frame is scaled from its design size; as it is,
/// nothing moves.
@Test func aStageChangesShapeByFittingOrFilling() {
    let page = #"<body data-width="1920" data-height="1080"><h1>Hi</h1></body>"#
    let fit = StageReframe.fit.apply(page, old: (1920, 1080), width: 1080, height: 1920)
    #expect(
        fit.contains(
            #"data-kelp-frame="1920x1080" style="position: absolute; left: 0px; top: 656.25px; width: 1920px; height: 1080px; transform: scale(0.5625)"#
        ))
    #expect(fit.contains("<h1>Hi</h1></div>"))
    let fill = StageReframe.fill.apply(fit, old: (1080, 1920), width: 1080, height: 1920)
    #expect(
        fill.contains("left: -1166.67px; top: 0px; width: 1920px")
            && fill.components(separatedBy: "data-kelp-frame").count == 2)
    // Music dropped after the frame stays, outside it, when the stage changes again.
    let withMusic = fill.replacingOccurrences(of: "</body>", with: #"<audio data-id="m" src="a.mp3"></audio></body>"#)
    let again = StageReframe.fit.apply(withMusic, old: (1080, 1920), width: 1920, height: 1080)
    #expect(
        again.contains(#"<h1>Hi</h1></div>"#) && again.contains("</div>\n<audio data-id=\"m\" src=\"a.mp3\"></audio>"))
    #expect(StageReframe.none.apply(page, old: (1920, 1080), width: 1080, height: 1920) == page)
}

/// A style for every element of a class: each with the class among others gets it, one with a longer class name that
/// starts the same doesn't, and a value that could end the attribute is refused.
@Test func everyElementOfAClassTakesAStyle() throws {
    let page = #"<div class="card big">A</div><div class="cards">B</div><p class="card" style="color: red">C</p>"#
    let (out, n) = try #require(BoardEdit.setStyle(page, className: "card", property: "border-radius", value: "12px"))
    #expect(n == 2)
    #expect(
        out
            == #"<div class="card big" style="border-radius: 12px">A</div><div class="cards">B</div><p class="card" style="color: red; border-radius: 12px">C</p>"#
    )
    #expect(BoardEdit.setStyle(page, className: "card", property: "color", value: "red\"") == nil)
}

/// Keeping a variation takes the board's variations off canvas.json and leaves everything else the agent wrote there.
@Test func keptVariationsLeaveTheCanvas() throws {
    let json =
        #"{"boards": [{"file": "boards/A.html", "w": 900}, {"file": "boards/A-b.html", "variant": "boards/A.html"}, {"file": "boards/B.html", "note": "mine"}], "pages": 2}"#
    let out = try ArtifactCanvas.editBoards(json) { $0.filter { ($0["variant"] as? String) != "boards/A.html" } }
    #expect(ArtifactCanvas.read(out)?.boards.map(\.file) == ["boards/A.html", "boards/B.html"])
    #expect(out.contains(#""note" : "mine""#) && out.contains(#""pages" : 2"#))
    #expect(throws: (any Error).self) { try ArtifactCanvas.editBoards("{", { $0 }) }
}

/// A dashboard's sources come from canvas.json, their output becomes a figure by its map, and each figure from a
/// source shows it with where and when it came from.
@Test func aDashboardsFiguresComeFromItsSources() throws {
    let json =
        #"{"boards": [], "sources": {"issues": {"run": "gh issue list --json number", "map": "length"}, "first": {"run": "gh pr list --json title", "map": "0.title"}}}"#
    let sources = DashboardSource.read(json)
    #expect(sources.map(\.name) == ["first", "issues"])
    #expect(try sources[1].value(#"[{"number": 1}, {"number": 2}]"#) == "2")
    #expect(try sources[0].value(#"[{"title": "Fix <it>"}]"#) == "Fix <it>")
    #expect(try DashboardSource(name: "x", run: "x", map: "lines").value("a\nb\nc\n") == "3")
    #expect(throws: (any Error).self) { try sources[1].value("not json") }
    let board = #"<b data-value data-from="issues" data-source="old">41</b> and <i data-from="issues">40</i>"#
    #expect(
        BoardEdit.setFigures(board, from: "issues", value: "42", note: "gh issue list, 10:00")
            == #"<b data-value data-from="issues" data-source="gh issue list, 10:00">42</b> and <i data-from="issues" data-source="gh issue list, 10:00">42</i>"#
    )
}

/// An entrance and an exit chosen by hand are kept on the element and written as one style of the page: keyframes
/// used and a rule; letters cut the text into numbered spans; taking them away takes the style away.
@Test func anEntranceAndAnExitAreWrittenAsOneStyle() throws {
    let page = #"<html><head><title>t</title></head><body><h1 data-id="t">Hi you</h1></body></html>"#
    let risen = try #require(
        MotionPresets.set(page, id: "t", .entrance, .init("rise", length: 0.8, easing: "ease-out", start: 1)))
    let both = try #require(
        MotionPresets.set(risen, id: "t", .exit, .init("fade-out", length: 0.4, easing: "ease-in", start: 5.6)))
    #expect(
        both.contains(#"data-kelp-in="rise 0.8 ease-out 1""#)
            && both.contains(#"data-kelp-out="fade-out 0.4 ease-in 5.6""#))
    #expect(
        both.contains(
            "@keyframes kelp-fade-out { to { opacity: 0 } }\n@keyframes kelp-rise { from { opacity: 0; translate: 0 40px } }"
        ))
    #expect(
        both.contains(
            #"[data-id='t'] { animation: kelp-rise 0.8s ease-out 1s both, kelp-fade-out 0.4s ease-in 5.6s both; }"#))
    let letters = try #require(
        MotionPresets.set(page, id: "t", .entrance, .init("words", length: 0.6, easing: "ease-out", start: 0)))
    #expect(letters.contains(#"<span style="--i: 0">Hi</span> <span style="--i: 1">you</span>"#))
    #expect(letters.contains("calc(0s + var(--i) * 0.12s)"))
    // Letters dragged on the timeline: the preset starts later, the spans' rule follows, the spans stay.
    let later = try #require(MotionPresets.shift(letters, id: "t", by: 1.5))
    #expect(
        later.contains(#"data-kelp-in="words 0.6 ease-out 1.5""#) && later.contains("calc(1.5s + var(--i) * 0.12s)"))
    #expect(later.contains(#"<span style="--i: 1">you</span>"#))
    let none = try #require(MotionPresets.set(risen, id: "t", .entrance, .init(nil, length: 0, easing: "", start: 0)))
    #expect(!none.contains("kelp-motion") && !none.contains("data-kelp-in"))
}

/// Subtitles from SRT and WebVTT become one block of cues in the page, styled by its look, and go back out as SRT.
@Test func subtitlesComeInAndGoOut() throws {
    let srt = "1\n00:00:00,200 --> 00:00:01,600\nКаждый день\n\n2\n00:00:01,700 --> 00:00:03,200\n<i>понемногу</i>\n"
    let vtt = "WEBVTT\n\n00:01.700 --> 00:03.200 align:middle\nпонемногу\n"
    let cues = Captions.parse(srt)
    #expect(cues == [.init(start: 0.2, end: 1.6, text: "Каждый день"), .init(start: 1.7, end: 3.2, text: "понемногу")])
    #expect(Captions.parse(vtt) == [cues[1]])
    // Typed lines share the time by their length, an edge near a beat moved onto it.
    let typed = Captions.timed("Каждый день\n\nпонемногу, но каждый день", over: 0...6, beats: [2, 4])
    #expect(typed.map(\.text) == ["Каждый день", "понемногу, но каждый день"])
    #expect(typed.map(\.start) == [0, 2] && typed[1].end == 6)   // 1.83 moved onto the beat at 2
    // Only the formats' own tags go: a "<" in the words stays, and an entity is read as its character.
    let words = "WEBVTT\n\n00:01.000 --> 00:02.000\n<v Аня><c.loud>от < 10 до > 5</c> &amp; <00:01.500>дальше\n"
    #expect(Captions.parse(words).map(\.text) == ["от < 10 до > 5 & дальше"])
    let page = Captions.write("<html><head></head><body></body></html>", cues: cues)
    #expect(page.contains(#"<p data-id="cap-2" data-start="1.7" data-duration="1.5">понемногу</p>"#))
    #expect(page.contains("bottom: 6%") && page.contains("rgba(0,0,0,.65)"))
    let outlined = try #require(Captions.setLook(page, "outline top 56"))
    #expect(outlined.contains("top: 6%") && outlined.contains("-webkit-text-stroke: 3px"))
    #expect(Captions.write(outlined, cues: [cues[0]]).components(separatedBy: "data-id=\"cap-").count == 2)
    #expect(
        Captions.srt(page)
            == "1\n00:00:00,200 --> 00:00:01,600\nКаждый день\n\n2\n00:00:01,700 --> 00:00:03,200\nпонемногу\n")
    // A video of the work area 1–3 s: its subtitles from its own start, cut to it; one styled by hand keeps its words.
    let styled = page.replacingOccurrences(of: ">понемногу<", with: "><b>понемногу</b><br>и<")
    #expect(
        Captions.srt(styled, over: 1...3)
            == "1\n00:00:00,000 --> 00:00:00,600\nКаждый день\n\n2\n00:00:00,700 --> 00:00:02,000\nпонемногу\nи\n")
    // A line of spaces between cues still parts them.
    #expect(Captions.parse(srt.replacingOccurrences(of: "день\n\n", with: "день\n  \n")) == cues)
}

/// Clicks every half second, from a quarter second in, are 120 BPM with their beats where the clicks are.
@Test func clicksAreFoundAsBeats() throws {
    let rate = 8000.0
    var samples = [Float](repeating: 0, count: Int(rate * 8))
    for click in stride(from: 0.25, to: 8, by: 0.5) {
        for i in 0..<200 { samples[Int(click * rate) + i] = sin(Float(i) / 2) * 0.8 }
    }
    let found = try #require(Beats.find(samples, rate: rate))
    #expect(abs(found.bpm - 120) < 1)
    #expect(found.times.count == 16)
    #expect(zip(found.times, stride(from: 0.25, to: 8, by: 0.5)).allSatisfy { abs($0 - $1) < 0.03 })
}

/// A design's controls and where they go: a link to a board by href="#board:…" or data-link, a dead end (a button, an
/// <a> going nowhere), and neither (an address outside the design, a form's submit).
@Test func aBoardsControlsSayWhereTheyGo() {
    let html = """
        <a data-id="next" href="#board:choose">Next</a> <button data-id="skip">Skip <b>it</b></button>
        <button data-link="remind">Later</button> <a href="https://x.dev">Site</a> <a href="#">Top</a>
        <button type="submit">Send</button>
        """
    let links = BoardLinks.controls(html, board: "boards/welcome.html")
    #expect(
        links.map { [$0.id, $0.words, $0.to ?? "-"] } == [
            ["next", "Next", "choose"], ["skip", "Skip it", "-"], ["", "Later", "remind"], ["", "Top", "-"]
        ])
    #expect(
        BoardLinks.lines(links, boards: ["boards/welcome.html", "boards/choose.html"]) == [
            "welcome:next → choose", "welcome:skip → (nothing)", "welcome:«Later» → remind (no such board)",
            "welcome:«Top» → (nothing)"
        ])
    #expect(BoardLinks.file("choose", in: ["boards/welcome.html", "boards/choose.html"]) == "boards/choose.html")
}

/// A 997 Hz sine at a tenth of full scale is −23 LUFS by BS.1770 (−3.01 at full scale); silence has no loudness.
@Test func aSineIsAsLoudAsTheStandardSays() throws {
    let rate = 48000.0
    let sine = (0..<Int(rate * 3)).map { Float(0.1 * sin(2 * Double.pi * 997 * Double($0) / rate)) }
    let lufs = try #require(Loudness.integrated(sine, rate: rate))
    #expect(abs(lufs - -23.01) < 0.1, "\(lufs)")
    #expect(Loudness.integrated([Float](repeating: 0, count: 48000), rate: rate) == nil)
}

/// A stereo file is read whole (a one-channel buffer can't take it): mixed for beats and bars, and its loudness counts
/// both channels, so the same sine in each is 3 LU louder than in one.
@Test func aStereoFileIsReadWithBothChannels() throws {
    let rate = 48000.0
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let count = Int(rate * 3)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
    buffer.frameLength = AVAudioFrameCount(count)
    for i in 0..<count {
        let v = Float(0.1 * sin(2 * Double.pi * 997 * Double(i) / rate))
        buffer.floatChannelData![0][i] = v
        buffer.floatChannelData![1][i] = v
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    let (mixed, read) = try Beats.samples(of: url)
    #expect(read == rate && mixed.count == count)
    let (channels, _) = try Beats.channels(of: url)
    let lufs = try #require(Loudness.integrated(channels: channels, rate: rate))
    #expect(abs(lufs - -20.0) < 0.1, "\(lufs)")
}

/// A chart's table is read as rows of text and written back with the numbers changed, the rest of the chart as it was.
@Test func aChartsNumbersAreReadAndWritten() throws {
    let page = """
        <figure data-id="rev" data-chart><svg></svg><table class="sr-only"><tr><th>Month</th><th>Revenue</th></tr>
        <tr><td>Jan</td><td>80</td></tr><tr><td>Feb</td><td>1 &amp; 2</td></tr></table></figure>
        """
    #expect(ChartData.read(page, id: "rev") == [["Month", "Revenue"], ["Jan", "80"], ["Feb", "1 & 2"]])
    let changed = try #require(ChartData.write(page, id: "rev", rows: [["Month", "Revenue"], ["Jan", "160"]]))
    #expect(changed.contains(#"<svg></svg><table class="sr-only"><tr><th>Month</th>"#))
    #expect(ChartData.read(changed, id: "rev") == [["Month", "Revenue"], ["Jan", "160"]])
    #expect(ChartData.read("<div data-id=\"x\"></div>", id: "x") == nil)
}

/// A CSV reads as rows, quotes and all; a page names the files its elements take columns of; a row names its file.
@Test func dataRowsAreReadFromACSV() {
    let csv = "name,city\r\n\"Иванова, Ольга\",Москва\n\"Say \"\"hi\"\"\",\"two\nlines\"\n\n"
    #expect(DataRows.parse(csv) == [["name", "city"], ["Иванова, Ольга", "Москва"], ["Say \"hi\"", "two\nlines"]])
    #expect(DataRows.parse("name;sum\nОльга;1,5\n") == [["name", "sum"], ["Ольга", "1,5"]])
    #expect(DataRows.parse("\u{FEFF}name;sum\r\nОльга;1,5\r\n") == [["name", "sum"], ["Ольга", "1,5"]])
    let page = #"<h2 data-field="clients.csv:name">Hi</h2><img data-field="clients.csv:photo"><p data-field="b.csv:x">"#
    #expect(DataRows.files(in: page) == ["clients.csv", "b.csv"])
    // A row put into the page as it is exported: text and a picture's address, the last row past the end.
    let card = #"<h2 data-field="c.csv:name">Name</h2><img alt="" src="x.png" data-field="c.csv:photo"><p>kept</p>"#
    let tables = ["c.csv": [["name", "photo"], ["Ольга & Co", "o.jpg"], ["Иван", "i.jpg"]]]
    #expect(
        DataRows.fill(card, row: 1, tables: tables)
            == #"<h2 data-field="c.csv:name">Ольга &amp; Co</h2><img src="o.jpg" alt="" data-field="c.csv:photo"><p>kept</p>"#
    )
    #expect(DataRows.fill(card, row: 9, tables: tables).contains(">Иван</h2>"))
    #expect(
        DataRows.name(["Ольга / Иванова"], index: 3) == "Ольга  Иванова" && DataRows.name([""], index: 3) == "row-3")
}
