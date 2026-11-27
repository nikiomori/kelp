import Core
import Foundation
import TestSupport
import Testing
import os

@testable import Daemon

/// A clone that runs stops at its cancel: git is interrupted, the clone says it was cancelled and its folder goes.
@Test func aRunningCloneIsCancelled() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let src = try makeRepo(), parent = tmp().path
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    // The source's refs are a pipe nobody writes to, so git waits on them until it is stopped.
    let refs = src + "/.git/packed-refs"
    try? FileManager.default.removeItem(atPath: refs)
    #expect(mkfifo(refs, 0o600) == 0)
    let ended = OSAllocatedUnfairLock<String?>(initialState: nil)
    let clone = Task {
        do {
            _ = try await c.call(
                "repo.clone", .obj(["url": .string("file://" + src), "parent": .string(parent), "id": "slow"]))
            ended.withLock { $0 = "cloned" }
        } catch { ended.withLock { $0 = (error as? RPCError)?.message ?? "\(error)" } }
    }
    // A cancel before git runs does nothing (`Clones.cancel`), so it is asked until the clone ends.
    #expect(
        try await waitFor(20) {
            _ = try await c.call(RepoCloneCancel(id: "slow"))
            return ended.withLock { $0 } != nil
        })
    // Not cancelled: the pipe gets a writer, held till the clone ends (git finds the refs empty and goes on), so the
    // test ends here, failed, instead of waiting for good.
    let writer = open(refs, O_WRONLY | O_NONBLOCK)
    await clone.value
    if writer >= 0 { close(writer) }
    #expect(ended.withLock { $0 }?.contains("Clone cancelled") == true, "\(String(describing: ended.withLock { $0 }))")
    #expect(!FileManager.default.fileExists(atPath: parent + "/" + (src as NSString).lastPathComponent))
}

/// A kelpd outside an app (a build folder, as here) has no switch in Login Items, so it says it may stay in the
/// background.
@Test func aDaemonOutsideAnAppMayStayInTheBackground() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    #expect(try await c.call(DaemonBackgroundAllowed()))
}

/// With the PATH given (KELP_LOGIN_PATH, as in tests) a refresh runs no shell and keeps it: `process.which` finds
/// what it found before.
@Test func aRefreshWithThePathGivenKeepsIt() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    let before = try await c.call(ProcessWhich(commands: ["git"]))
    _ = try await c.call(ProcessRefreshPath())
    let after = try await c.call(ProcessWhich(commands: ["git"]))
    #expect(before["git"] != nil && after == before)
}

/// Turning on the next edit without llama.cpp says so (`noServer`), for the switch to offer the install. Left out where
/// llama-server is on the PATH: a start there would download its model (1.5 GB).
@Test(.enabled(if: LoginPath.find("llama-server") == nil)) func theNextEditWithoutLlamaCppSaysSo() async throws {
    let (d, c, _) = try daemon()
    defer { d.stop() }
    #expect(try await c.call(EditorNextEditStart()).problem == .noServer)
}
