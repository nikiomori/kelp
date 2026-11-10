import AppKit
import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// A Linux or macOS machine whose window is on screen is in use: kelpd's memory budget is told so, and a sleep it asks
/// for (`if-idle`) is refused; the user's own sleep isn't.
@MainActor @Test func aWindowOnScreenIsUseAndTheBudgetsSleepIsRefused() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vm-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let linux = VMMachine(name: "box", os: "linux", image: "i", cpus: 2, memoryMiB: 2048, diskGiB: 8, user: "u")
    try JSONEncoder().encode(linux).write(to: folder.appendingPathComponent("machine.json"))
    let vm = try Runtime(folder: folder)
    vm.exitProcess = {}   // a sleep with nothing to save ends kelp-vm
    func ask(_ request: VMHelper.Request) async -> String? {
        await withCheckedContinuation { c in vm.handle(request) { error, _ in c.resume(returning: error) } }
    }
    #expect(vm.answer(nil).connections == 0)
    #expect(await ask(.sleepIfIdle) == nil, "idle: the budget's sleep goes ahead")
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil) }
    window.orderFront(nil)
    try #require(window.isVisible)
    vm.window = window
    #expect(vm.answer(nil).connections == 1, "the window counts as use")
    #expect(await ask(.sleepIfIdle)?.contains("in use") == true)
    #expect(await ask(.init(op: .sleep)) == nil, "the user's own sleep isn't refused")
}

/// A child an earlier kelp-vm noted (and was killed before it ended it) is ended by the next one, SIGTERM ignored or
/// not; a note whose process has gone, or whose pid is someone else's now, ends nothing.
@MainActor @Test func aChildLeftByAKilledKelpVMIsEndedByTheNext() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vm-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let child = try Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec sleep 60"])
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
    Lifecycle.remember(child, in: folder, as: "emulator")
    let note = folder.appendingPathComponent("emulator.child")
    #expect(FileManager.default.fileExists(atPath: note.path))
    Lifecycle.endLeftover(in: folder, "emulator")
    #expect(try await waitFor(3) { !child.isRunning }, "ended, though it ignores SIGTERM")
    #expect(!FileManager.default.fileExists(atPath: note.path))
    // Another process under the noted pid (a start time that isn't the note's): left alone.
    let other = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
    defer { other.terminate() }
    try "\(other.processIdentifier) 1".write(to: note, atomically: true, encoding: .utf8)
    Lifecycle.endLeftover(in: folder, "emulator")
    #expect(other.isRunning)
}

/// The budget's sleep is refused by an Android machine whose window the user has; the user's own goes ahead.
extension AndroidRuntimeOnAStandIn {
    @Test(.timeLimit(.minutes(1))) func anAndroidWindowRefusesTheBudgetsSleep() async throws {
        let (vm, sdk, putAway) = try androidStandIn()
        defer { putAway() }
        #expect(await askAndroid(vm, .init(op: .show)) == nil)
        #expect(await askAndroid(vm, .sleepIfIdle)?.contains("in use") == true)
        #expect(vm.state == .running)
        #expect(try !String(contentsOf: sdk.appendingPathComponent("adb.log"), encoding: .utf8).contains("emu kill"))
        #expect(await askAndroid(vm, .init(op: .sleep)) == nil)
        #expect(vm.state == .sleeping)
    }
}

/// A stand-in Android machine (`standIn`), and how to put it away: its emulator ended, its SDK removed, ANDROID_HOME
/// as it was.
@MainActor func androidStandIn(booting: String = "", adb: String = "") throws -> (AndroidRuntime, URL, () -> Void) {
    let before = ProcessInfo.processInfo.environment["ANDROID_HOME"]
    let (vm, sdk) = try standIn(booting: booting, adb: adb)
    return (
        vm, sdk,
        {
            let pidFile = sdk.appendingPathComponent("emulator.pid")
            // still ours: not a number some other process has since
            if let text = String(contentsIfAny: pidFile), let pid = pid_t(text.trimmingCharacters(in: .newlines)),
                Subprocess.parent(pid) == getpid()
            {
                kill(pid, SIGKILL)
            }
            if let before { setenv("ANDROID_HOME", before, 1) } else { unsetenv("ANDROID_HOME") }
            try? FileManager.default.removeItem(at: sdk)
        }
    )
}

@MainActor func askAndroid(_ vm: AndroidRuntime, _ request: VMHelper.Request) async -> String? {
    await withCheckedContinuation { c in vm.handle(request) { c.resume(returning: $0) } }
}
