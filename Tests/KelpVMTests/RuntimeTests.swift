import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// A Linux or macOS machine's runtime as far as it goes without Virtualization starting one: its shared folders,
/// stopping, quitting and SIGTERM while it's down (its answer to each request from each state is RuntimeTablesTests').
@MainActor @Suite struct RuntimeWithoutAVM {
    /// sshd answered, then the guest stopped while its one command ran (here: there's no VM, and ssh fails at once): it
    /// isn't running with no VM, which no command could reach and no tick would pause.
    @Test func aGuestGoneDuringItsFirstCommandIsntRunning() async throws {
        let folder = try machine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let vm = try Runtime(folder: folder)
        await vm.answered(true, false, Date())?.value
        #expect(vm.state == .off)
    }

    /// Each folder shared gets a slot of its own, the same one when it's asked again; all taken, an idle machine gives
    /// the least recently asked one up. The slots are kept in shares.json for the next kelp-vm.
    @Test func sharedFoldersTakeSlotsTheOldestGivenUp() async throws {
        let folder = try machine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let vm = try Runtime(folder: folder)
        func share(_ path: String) async -> Int? { await ask(vm, .init(op: .share, path: path)).slot }
        #expect(await share("/a") == 0)
        #expect(await share("/b") == 1)
        #expect(await share("/a") == 0, "the same folder, the same slot")
        for index in 2..<VMs.shareSlots { #expect(await share("/\(index)") == index) }
        #expect(await share("/new") == 1, "/b was asked for longest ago")
        let kept = try JSONDecoder().decode(
            [Int: String].self, from: Data(contentsOf: folder.appendingPathComponent("shares.json")))
        #expect(kept[1] == "/new" && kept[0] == "/a" && kept.count == VMs.shareSlots)
        #expect(await ask(vm, .init(op: .share)).error == "share: a path")
    }

    /// A stop forgets a saved state (the next start boots), then kelp-vm ends.
    @Test func aStopForgetsTheSavedState() async throws {
        let folder = try machine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("state.vzsave")
        FileManager.default.createFile(atPath: saved.path, contents: nil)
        let vm = try Runtime(folder: folder)
        var ended = false
        vm.exitProcess = { ended = true }
        #expect(await ask(vm, .init(op: .stop)).error == nil)
        #expect(vm.state == .off && !FileManager.default.fileExists(atPath: saved.path))
        #expect(try await waitFor(2) { ended })
    }

    /// Down, a quit for a new size goes ahead and SIGTERM ends it at once: nothing to save or shut down.
    @Test func downItQuitsAndLeavesAtOnce() async throws {
        let folder = try machine()
        defer { try? FileManager.default.removeItem(at: folder) }
        for leave in [true, false] {
            let vm = try Runtime(folder: folder)
            var ended = false
            vm.exitProcess = { ended = true }
            if leave {
                vm.leave()
            } else {
                #expect(await ask(vm, .init(op: .quit, args: ["if-down"])).error == nil)
            }
            #expect(try await waitFor(2) { ended }, "leave: \(leave)")
            #expect(vm.state == .off)
        }
    }
}

/// A tick pauses a machine idle past `pauseAfter` and sleeps a paused one idle past `sleepAfter`; one in use stays.
@Test func whatATickDoesWithAnIdleMachine() {
    let pause = Runtime.pauseAfter, sleep = Runtime.sleepAfter
    let rows: [(VMState, TimeInterval, Bool, Lifecycle.IdleStep?)] = [
        (.running, pause - 1, false, nil), (.running, pause + 1, false, .pause), (.running, sleep + 1, true, nil),
        (.paused, pause + 1, false, nil), (.paused, sleep + 1, false, .sleep), (.paused, sleep + 1, true, nil),
        (.starting, sleep + 1, false, nil), (.sleeping, sleep + 1, false, nil), (.off, sleep + 1, false, nil)
    ]
    for (state, idle, inUse, step) in rows {
        #expect(Lifecycle.idleStep(state, idle: idle, inUse: inUse) == step, "\(state), \(idle) s, in use: \(inUse)")
    }
}

/// A Linux machine's folder, nothing made in it yet (no disk: a boot fails before Virtualization runs anything).
private func machine() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vm-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let linux = VMMachine(name: "box", os: "linux", image: "i", cpus: 2, memoryMiB: 2048, diskGiB: 8, user: "u")
    try JSONEncoder().encode(linux).write(to: folder.appendingPathComponent("machine.json"))
    return folder
}

@MainActor private func ask(_ vm: Runtime, _ request: VMHelper.Request) async -> (error: String?, slot: Int?) {
    await withCheckedContinuation { c in vm.handle(request) { c.resume(returning: ($0, $1)) } }
}
