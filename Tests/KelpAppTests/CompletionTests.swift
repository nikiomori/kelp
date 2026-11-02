import AppKit
import Foundation
import Testing
@testable import EditorKit

@Test func itemsStartingWithWhatsTypedComeFirstThenTheRest() {
    let items = ["reduce", "append", "appendAll", "myApp", "aXpXp"].map { CodeEditor.Completion(label: $0, insert: $0) }
    #expect(CompletionFilter.ranked(items, typed: "app").map(\.label) == ["append", "appendAll", "myApp", "aXpXp"])
    #expect(CompletionFilter.ranked(items, typed: "").count == 5)
    #expect(CompletionFilter.ranked(items, typed: "zz").isEmpty)
}

@Test func aSnippetsTextAndStops() {
    let (text, stops) = Snippet.parse("a $1 ${2:two} ${3|x,y|} $1 \\$9 $0")
    #expect(text == "a  two x  $9 ")
    #expect(stops.count == 4)
    #expect(stops[0] == [NSRange(location: 2, length: 0), NSRange(location: 9, length: 0)])    // $1 twice
    #expect(stops[1] == [NSRange(location: 3, length: 3)])
    #expect(stops[3] == [NSRange(location: 13, length: 0)])                                     // $0 last
    #expect(Snippet.parse("plain").stops.isEmpty)
    #expect(Snippet.parse("${1:outer ${2:in}}").text == "outer in")
}
