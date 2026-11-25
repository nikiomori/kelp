import Core
import Foundation
import Testing

/// What `kelp browser open` takes as typed: a local address is http, a bare host https, a URL as it is.
@Test func aBrowserAddressGetsItsScheme() {
    #expect(BrowserWords.address("localhost:3000") == "http://localhost:3000")
    #expect(BrowserWords.address("127.0.0.1:8080/x") == "http://127.0.0.1:8080/x")
    #expect(BrowserWords.address("example.com") == "https://example.com")
    #expect(
        BrowserWords.address("file:///tmp/a.html") == "file:///tmp/a.html"
            && BrowserWords.address("about:blank") == "about:blank")
    #expect(BrowserWords.address("preview:/tmp/a.html") == "preview:/tmp/a.html")   // a local page, as `kelp open` refuses it
}

/// An action's answer reads as one line, what came under it; a line from stdin splits into words as a shell would.
@Test func aBrowserAnswerIsALine() {
    let clicked: JSONValue = .object([
        "change": .string("page changed"), "element": .string(#"button "Check""#), "url": .string("http://x/"),
        "title": .string("X"), "new": .string(#"- text: "Invalid" [new]"#), "dialogs": .array([.string("alert \"Hi\"")])
    ])
    #expect(
        BrowserWords.text(.click, "e1", clicked)
            == "click e1 button \"Check\" → page changed\ndialog: alert \"Hi\"\n- text: \"Invalid\" [new]")
    let went: JSONValue = .object([
        "change": .string("new page"), "url": .string("http://x/two"), "title": .string("Two")
    ])
    #expect(BrowserWords.text(.click, "e3", went) == #"click e3 → new page "Two" http://x/two"#)
    let typed: JSONValue = .object(["shows": .string("+7 99"), "url": .string("u"), "title": .string("t")])
    #expect(BrowserWords.text(.type, "e5", typed) == #"type e5 → shows "+7 99""#)
    #expect(BrowserWords.text(.press, "Escape", .object([:])) == "press Escape → done")
    #expect(
        BrowserWords.text(.open, "", .object(["url": .string("u"), "title": .string("A \"b\"")]))
            == #"page "A \"b\"" u"#
    )
    #expect(BrowserWords.text(.snapshot, "", .string("- page")) == nil)
    #expect(BrowserWords.text(.eval, "", .object(["n": .int(1)])) == nil)   // eval's value, as the page gave it
    #expect(ShellQuote.words(#"type e3 "a b" 'c "d"' e\ f"#) == ["type", "e3", "a b", #"c "d""#, "e f"])
    #expect(ShellQuote.words("  drag e1   '#col'  ") == ["drag", "e1", "#col"])
}

/// `kelp browser <action> …`: the words after the action become its parameters, flags wherever they stand. A path is
/// read where the agent is (its own `Files`), which on a host is the host's folder.
@Test func aBrowserActionsWordsBecomeItsParameters() throws {
    let here = BrowserWords.Files(
        path: {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: "/srv/shop", isDirectory: true))
                .standardizedFileURL.path
        },
        read: { $0 == "/srv/shop/a.txt" ? Data("hi".utf8) : nil }, stdin: { "document.title" })
    let rows: [(BrowserAction, [String], [String: JSONValue])] = [
        (.open, ["localhost:3000", "--shared"], ["url": "http://localhost:3000", "shared": true]),
        (.open, ["example.com"], ["url": "https://example.com", "shared": false]),
        (.click, ["e2"], ["ref": "e2"]),
        (.press, ["Enter", "e3"], ["key": "Enter", "ref": "e3"]),
        (.drag, ["e1", ".list li"], ["ref": "e1", "onto": ".list li"]),
        (.scroll, [], ["to": "down"]),
        (.type, ["e4", "--submit", "hello", "world"], ["ref": "e4", "text": "hello world", "submit": true]),
        (.eval, ["1", "+", "2"], ["js": "1 + 2"]),
        (.screenshot, ["/tmp/a/../s.png"], ["path": "/tmp/s.png"]),
        (.record, ["stop"], ["stop": true]),
        (.wait, ["--text", "Done", "--timeout", "2.5"], ["text": "Done", "timeout": .double(2.5)]),
        (.network, ["--clear"], ["clear": true]),
        (.snapshot, ["--find", "Buy", "e5"], ["find": "Buy", "ref": "e5"]),
        (.dialog, ["accept", "my", "name"], ["answer": "accept", "text": "my name"]),
        (.viewport, ["390x844"], ["size": "390x844"]),
        (.back, [], [:]),
        (.eval, ["-"], ["js": "document.title"]),
        (.screenshot, ["shots/s.png"], ["path": "/srv/shop/shots/s.png"]),
        (
            .upload, ["e1", "a.txt"],
            [
                "ref": "e1",
                "files": .array([
                    .object([
                        "name": "a.txt", "type": "text/plain", "data": .string(Data("hi".utf8).base64EncodedString())
                    ])
                ])
            ]
        )
    ]
    for (action, words, expected) in rows {
        var words = words
        #expect(try BrowserWords.params(action, &words, here) == expected, "\(action) \(words)")
    }
    var missing = ["e1", "gone.png"]
    #expect(throws: BrowserWords.Wrong("Can't read gone.png")) { try BrowserWords.params(.upload, &missing, here) }
}
