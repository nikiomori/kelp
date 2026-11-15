import Foundation
import TestSupport
import Testing
import os

@testable import Core

/// A file is read again only once it was written to (its size or last write moved); one that's gone, every time.
@Test func aFileIsReadAgainOnlyOnceWrittenTo() throws {
    let file = tmp().appendingPathComponent("t.jsonl")
    try "a\n".write(to: file, atomically: false, encoding: .utf8)
    let memo = StatMemo<String?>(), reads = OSAllocatedUnfairLock(initialState: 0)
    func read() -> String? {
        memo.value(file.path) {
            reads.withLock { $0 += 1 }
            return try? String(contentsOf: file, encoding: .utf8)
        }
    }
    #expect(read() == "a\n" && read() == "a\n" && reads.withLock { $0 } == 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("b\n".utf8))
    try handle.close()
    #expect(read() == "a\nb\n" && reads.withLock { $0 } == 2)
    // The same size, written again: its last write moved.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
    #expect(read() == "a\nb\n" && reads.withLock { $0 } == 3)
    try FileManager.default.removeItem(at: file)
    #expect(read() == nil && read() == nil && reads.withLock { $0 } == 5)
}
