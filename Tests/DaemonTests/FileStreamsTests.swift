import Core
import Foundation
import TestSupport
import Testing
import os

@testable import Daemon

/// A folder in a watched one rides its stream and hears only its own events; the stream goes with its last hold. A build
/// folder's events a stream drops, so a folder in one gets a stream of its own.
@Test func foldersInAWatchedOneShareItsStream() async throws {
    let root = try #require(Paths.real(tmp().path)), sub = root + "/sub"
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
    let streams = FileStreams()
    let heardRoot = OSAllocatedUnfairLock<Set<String>>(initialState: []), heardSub = heardRoot.copy()
    var top: FileStreams.Hold? = streams.hold(root) { c in heardRoot.withLock { $0.formUnion(c.map(\.path)) } }
    var inner: FileStreams.Hold? = streams.hold(sub + "/") { c in heardSub.withLock { $0.formUnion(c.map(\.path)) } }
    #expect(streams.count == 1)
    #expect(
        try await waitFor(10) {   // written till heard: FSEvents starts reporting a moment after
            try "a".write(toFile: root + "/a.txt", atomically: false, encoding: .utf8)
            try "b".write(toFile: sub + "/b.txt", atomically: false, encoding: .utf8)
            return heardRoot.withLock { $0.isSuperset(of: [root + "/a.txt", sub + "/b.txt"]) }
        })
    #expect(try await waitFor(10) { heardSub.withLock { $0.contains(sub + "/b.txt") } })
    #expect(!heardSub.withLock { $0.contains(root + "/a.txt") })
    withExtendedLifetime(top) {}   // held till here
    top = nil
    #expect(streams.count == 1)
    #expect(
        try await waitFor(10) {   // the folder in it holds the stream still, and only it hears
            try "c".write(toFile: sub + "/c.txt", atomically: false, encoding: .utf8)
            return heardSub.withLock { $0.contains(sub + "/c.txt") }
        })
    #expect(!heardRoot.withLock { $0.contains(sub + "/c.txt") })
    withExtendedLifetime(inner) {}
    inner = nil
    #expect(streams.count == 0)
    #expect(FileStreams.covers("/r", "/r/src") && FileStreams.covers("/r", "/r") && !FileStreams.covers("/r", "/rx"))
    #expect(!FileStreams.covers("/r", "/r/node_modules/pkg"))
}

extension OSAllocatedUnfairLock where State == Set<String> {
    fileprivate func copy() -> OSAllocatedUnfairLock<Set<String>> { .init(initialState: withLock { $0 }) }
}
