import Foundation
import Testing
import Core
@testable import GitKit

@Test func searchTakesWholeWordsCaseAndPatterns() throws {
    let repo = try tempRepo()
    try "id\nvalid\nID\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
    #expect(try ProjectFiles.search(repo, query: "id").count == 3)
    #expect(try ProjectFiles.search(repo, query: "id", wholeWord: true).map(\.line) == [1, 3])
    #expect(try ProjectFiles.search(repo, query: "id", caseSensitive: true, wholeWord: true).map(\.line) == [1])
    #expect(try ProjectFiles.search(repo, query: "^v.*d$", regex: true).map(\.line) == [2])
    #expect(throws: (any Error).self) { try ProjectFiles.search(repo, query: "(", regex: true) }
}
