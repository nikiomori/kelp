import Foundation
import TestSupport
import Testing

@testable import Core
@testable import GitKit

/// A new file's lines are read again only once its size or date moved: an agent writing another file doesn't have every
/// new one read on each change.
@Test func aNewFilesLinesAreReadAgainOnlyWhenItChanges() throws {
    let path = try tempRepo() + "/new.txt", then = Date(timeIntervalSince1970: 1_700_000_000)
    func count(_ text: String, at date: Date) throws -> Int? {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        return Git.lineCount(URL(fileURLWithPath: path))
    }
    #expect(try count("a\nb\nc\n", at: then) == 3)
    #expect(try count("abcdef", at: then) == 3)   // the same size and date: as remembered
    #expect(try count("abcdef", at: then + 1) == 0)
}

/// A status already read says whether a folder holds work as `isDirty` would: a new link alone isn't any.
@Test func aStatusReadSaysWhetherAFolderIsDirty() throws {
    let repo = try Paths.real(tempRepo()) ?? ""
    try FileManager.default.removeItem(atPath: repo + "/.env")
    try FileManager.default.createSymbolicLink(atPath: repo + "/Vendor", withDestinationPath: "/tmp")
    #expect(!Git.isDirty(try Git.status(repo, remotes: .none), in: repo))
    try "x\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
    #expect(Git.isDirty(try Git.status(repo, remotes: .none), in: repo))
}
