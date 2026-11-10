import Foundation
import Testing

@testable import Core
@testable import GitKit

/// An edit saved after a discard took its undo copy, before it threw the change away, isn't in that copy: the file is
/// left as it is, not lost.
@Test func anEditSavedDuringADiscardIsNotThrownAway() throws {
    let repo = try tempRepo()
    try "mine\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    #expect(throws: GitError.self) {
        try Git.discard(repo, files: ["f.txt"]) { _ in
            try "saved meanwhile\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        }
    }
    #expect(try String(contentsOfFile: repo + "/f.txt", encoding: .utf8) == "saved meanwhile\n")
}
