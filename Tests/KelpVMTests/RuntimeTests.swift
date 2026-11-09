import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// A Linux or macOS machine's runtime as far as it goes without Virtualization starting one: its first state, a boot
/// that fails, its shared folders, stopping, quitting and SIGTERM while it's down.
@MainActor @Suite struct RuntimeWithoutAVM {
    /// A machine with a saved state starts out asleep (the next start restores it), one without it off.
    @Test func itStartsOutWhereItWasLeft() throws {
        let folder = try machine()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try Runtime(folder: folder).state == .off)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("state.vzsave").path, contents: nil)
        #expect(try Runtime(folder: folder).state == .sleeping)
    }

    /// A boot that fails (no disk; in a test, Virtualization refuses its configuration first) is told to who waited,
    /// leaves no VM, and is tried again by the next start; a sleep then has nothing to save, and kelp-vm ends.
    @Test func aBootThatFailsIsToldAndTriedAgain() async throws {
        let folder = try machine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let vm = try Runtime(folder: folder)
        var ended = false
        vm.exitProcess = { ended = true }
        let first = await ask(vm, .init(op: .start)).error
        #expect(first?.isEmpty == false)
        #expect(vm.state == .error)
        #expect(await ask(vm, .begin(show: false)).error == nil, "kelpd's wake is answered as it starts")
        #expect(vm.state == .error, "and that boot failed too")
        #expect(await ask(vm, .init(op: .sleep)).error == nil)
        #expect(try await waitFor(2) { ended })
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

/// What a machine can't do is refused in words, whatever it is: a Linux one's screen, an Android or iOS one's folders.
@MainActor @Test func whatAMachineCantDoIsRefused() async throws {
    let folder = try machine()
    defer { try? FileManager.default.removeItem(at: folder) }
    let linux = try Runtime(folder: folder)
    #expect(await ask(linux, .init(op: .screen)).error == "Its screen is a macOS machine's.")
    let phone = VMMachine(name: "phone", os: "android", image: "i", cpus: 2, memoryMiB: 2048, diskGiB: 8, user: "u")
    let android = AndroidRuntime(folder: folder, machine: phone)
    let ios = IOSRuntime(folder: folder, machine: phone)
    for op in [VMHelper.Request.Operation.share, .screen] {
        let answers = [
            await withCheckedContinuation { c in android.handle(.init(op: op)) { c.resume(returning: $0) } },
            await withCheckedContinuation { c in ios.handle(.init(op: op)) { c.resume(returning: $0) } }
        ]
        #expect(answers.allSatisfy { $0?.isEmpty == false }, "\(op)")
    }
    #expect(android.state == .off && ios.state == .off, "nothing started")
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
