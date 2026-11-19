import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// A new size waits for a machine that's down: not one running, nor one whose boot is being tried again (no VM for a
/// second, still starting), which a quit would cut. Asked by its field, or by `args` as a kelpd before it asked.
@Test func aQuitForANewSizeWaitsForAMachineThatsDown() {
    func refuses(_ request: VMHelper.Request, _ hasVM: Bool, _ state: VMState) -> Bool {
        Lifecycle.refusesQuit(request, hasVM: hasVM, state: state, name: "m") != nil
    }
    let older = VMHelper.Request(op: .quit, args: ["if-down"])
    #expect(refuses(.quitIfDown, true, .running) && refuses(older, true, .running))
    #expect(refuses(.quitIfDown, false, .starting))
    #expect(!refuses(.quitIfDown, false, .off))
    #expect(!refuses(.init(op: .quit), true, .running))   // a plain quit (a delete) goes on
}

/// A state moves only where `Lifecycle.moves` lets it (and to off or error from anywhere); any other move is refused
/// and leaves it as it was. The moves no runtime may make are named: up without starting, paused while down, asleep
/// from a failure or while starting, back to being made.
@Test func aStateMovesOnlyWhereItsTableLetsIt() {
    for from in VMState.allCases {
        for to in VMState.allCases {
            var state = from
            Lifecycle.move(&state, to: to)
            #expect(state == (Lifecycle.allowed(from, to) ? to : from), "\(from) → \(to)")
        }
    }
    let never: [(VMState, VMState)] = [
        (.off, .running), (.sleeping, .running), (.error, .running), (.off, .paused), (.error, .sleeping),
        (.starting, .paused), (.starting, .sleeping), (.running, .starting), (.running, .creating),
        (.creating, .running)
    ]
    for (from, to) in never { #expect(!Lifecycle.allowed(from, to), "\(from) → \(to)") }
    #expect(VMState.allCases.allSatisfy { Lifecycle.allowed($0, .off) && Lifecycle.allowed($0, .error) })
}

/// What a kind doesn't do is said the same by each runtime.
@Test func whatAKindDoesntDoIsSaidOnce() {
    func machine(_ os: String) -> VMMachine {
        VMMachine(name: os, os: os, image: os, cpus: 1, memoryMiB: 1024, diskGiB: 8, user: "u")
    }
    #expect(
        Lifecycle.unsupported(.share, machine("android")) != nil && Lifecycle.unsupported(.share, machine("ios")) != nil
    )
    #expect(
        Lifecycle.unsupported(.share, machine("linux")) == nil && Lifecycle.unsupported(.share, machine("macos")) == nil
    )
    #expect(
        Lifecycle.unsupported(.screen, machine("macos")) == nil && Lifecycle.unsupported(.screen, machine("ios")) != nil
    )
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
    let second = try #require(Lifecycle.hold(folder, tries: scaled(10)))   // …which its tries (half a second) outlast
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
            for part in chunks {
                _ = part.withCString { Darwin.write(mine, $0, strlen($0)) }
                usleep(20_000)   // apart: the request arrives in pieces, which is what's tested
            }
            shutdown(mine, SHUT_WR)
        }
        close(mine)
        close(theirs)
        return got
    }
    #expect(await read(["{\"op\":", "\"sleep\"}\n{\"op\":\"stop\"}\n"])?.op == .sleep)
    #expect(await read(["{\"op\":\"status\"}"])?.op == .status)   // its end is its line's end
    #expect(await read(["not json\n"]) == nil)
}

/// Two machines woken a moment apart never get the same port, though neither listens on it yet: a port is claimed (a
/// lock in the machines' folder, `flock`'s, so another kelp-vm's too) until its claim is let go.
@Test func twoMachinesNeverClaimOnePort() throws {
    let machines = FileManager.default.temporaryDirectory.appendingPathComponent("vms-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: machines) }
    let a = Lifecycle.claimPort(from: 9300, in: machines), b = Lifecycle.claimPort(from: 9300, in: machines)
    defer { close(b.fd) }
    #expect(a.fd >= 0 && b.fd >= 0 && a.port != b.port)
    close(a.fd)
    let c = Lifecycle.claimPort(from: 9300, in: machines)
    defer { close(c.fd) }
    #expect(c.port == a.port, "let go, it's free again")
}
