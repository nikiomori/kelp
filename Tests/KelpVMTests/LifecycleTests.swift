import Core
import Foundation
import Testing
@testable import KelpVM

/// A new size waits for a machine that's down: not one running, nor one whose boot is being tried again (no VM for a
/// second, still starting), which a quit would cut.
@Test func aQuitForANewSizeWaitsForAMachineThatsDown() {
    #expect(Lifecycle.refusesQuit(["if-down"], hasVM: true, state: .running))
    #expect(Lifecycle.refusesQuit(["if-down"], hasVM: false, state: .starting))
    #expect(!Lifecycle.refusesQuit(["if-down"], hasVM: false, state: .off))
    #expect(!Lifecycle.refusesQuit(nil, hasVM: true, state: .running))   // a plain quit (a delete) goes on
}

/// kelp-vm ends after a sleep only with its machine down: not after a failed save, nor while a boot goes on.
@Test func kelpVMEndsAfterASleepOnlyWithItsMachineDown() {
    #expect(Lifecycle.endsAfterSleep(error: nil, hasVM: false, state: .sleeping))
    #expect(!Lifecycle.endsAfterSleep(error: "disk full", hasVM: true, state: .paused))
    #expect(!Lifecycle.endsAfterSleep(error: nil, hasVM: false, state: .starting))
    #expect(!Lifecycle.endsAfterSleep(error: nil, hasVM: true, state: .starting))
}

/// One kelp-vm holds a machine's folder; a second gives up. kelpd's look (shared) sees one runs without taking it, and
/// a look at the instant one starts keeps it out only for that instant: hence its half second of tries.
@Test func oneKelpVMHoldsAMachine() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kvm-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let look = open(folder.appendingPathComponent("kelp-vm.lock").path, O_CREAT | O_RDWR, 0o600)
    defer { close(look) }
    let first = try #require(Lifecycle.hold(folder))
    #expect(flock(look, LOCK_SH | LOCK_NB) != 0)   // kelpd sees it runs
    #expect(Lifecycle.hold(folder, tries: 2) == nil)   // a second one gives up
    close(first)
    #expect(flock(look, LOCK_SH | LOCK_NB) == 0)   // a look as one starts…
    #expect(Lifecycle.hold(folder, tries: 0) == nil)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { flock(look, LOCK_UN) }
    let second = try #require(Lifecycle.hold(folder))   // …which its tries outlast
    close(second)
}

/// A request read off the control socket whole, however its line arrives (in pieces, with more after it), and none
/// from a line that isn't one.
@Test func aControlRequestIsReadByItsLine() async throws {
    func read(_ chunks: [String]) async -> VMHelper.Request? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        let (mine, theirs) = (fds[0], fds[1])
        let got = await withCheckedContinuation { (c: CheckedContinuation<VMHelper.Request?, Never>) in
            Control.read(theirs) { c.resume(returning: $0) }
            for part in chunks { _ = part.withCString { Darwin.write(mine, $0, strlen($0)) }; usleep(20_000) }
            shutdown(mine, SHUT_WR)
        }
        close(mine); close(theirs)
        return got
    }
    #expect(await read(["{\"op\":", "\"sleep\"}\n{\"op\":\"stop\"}\n"])?.op == .sleep)
    #expect(await read(["{\"op\":\"status\"}"])?.op == .status)   // its end is its line's end
    #expect(await read(["not json\n"]) == nil)
}
