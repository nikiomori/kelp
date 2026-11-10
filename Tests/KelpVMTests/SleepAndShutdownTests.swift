import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// An Android sleep that didn't save says so, and leaves the machine where the next request goes on from.
extension AndroidRuntimeOnAStandIn {
    /// adb can't reach the emulator: the sleep fails, the emulator is still up and running, and a start finds it so.
    @Test(.timeLimit(.minutes(1))) func aSleepAdbCouldntAskFailsAndLeavesItUp() async throws {
        let (vm, sdk, putAway) = try androidStandIn(adb: #"*"emu kill"*) exit 1 ;;"#)
        defer { putAway() }
        #expect(await askAndroid(vm, .init(op: .start)) == nil)
        #expect(await askAndroid(vm, .init(op: .sleep))?.contains("still up") == true)
        #expect(vm.state == .running)
        #expect(FileManager.default.fileExists(atPath: sdk.appendingPathComponent("emulator.pid").path))
        #expect(await askAndroid(vm, .init(op: .start)) == nil)
        #expect(try boots(sdk) == 1, "the same emulator, not a second on its AVD")
    }

    /// The emulator quits but writes no snapshot: the sleep fails, the machine is off, and the next start boots it.
    @Test(.timeLimit(.minutes(1))) func aSleepThatSavedNothingFailsAndTheNextStartBoots() async throws {
        let quit = #"*"emu kill"*) kill "$(cat "$ANDROID_HOME/emulator.pid")"; rm -f "$ANDROID_HOME/emulator.pid" ;;"#
        let (vm, sdk, putAway) = try androidStandIn(adb: quit)
        defer { putAway() }
        #expect(await askAndroid(vm, .init(op: .start)) == nil)
        #expect(await askAndroid(vm, .init(op: .sleep))?.contains("without saving") == true)
        #expect(vm.state == .off)
        #expect(await askAndroid(vm, .init(op: .start)) == nil)
        #expect(try vm.state == .running && boots(sdk) == 2)
    }

    /// An emulator that ignores both `emu kill` and SIGTERM is killed once its 30 s are up: the sleep says its state
    /// isn't saved, and nothing is left holding the AVD.
    @Test(.timeLimit(.minutes(1))) func anEmulatorThatWontQuitIsKilledAndTheSleepSaysSo() async throws {
        let (vm, sdk, putAway) = try androidStandIn(booting: "trap '' TERM", adb: #"*"emu kill"*) ;;"#)
        defer { putAway() }
        #expect(await askAndroid(vm, .init(op: .start)) == nil)
        let text = try String(contentsOf: sdk.appendingPathComponent("emulator.pid"), encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .newlines)))
        var clock = Date()
        vm.now = {   // each look at the clock is 10 s on: its 30 s are up at once
            clock += 10
            return clock
        }
        #expect(await askAndroid(vm, .init(op: .sleep))?.contains("didn't quit") == true)
        #expect(vm.state == .off)
        #expect(try await waitFor(3) { kill(pid, 0) != 0 }, "killed, though it ignores SIGTERM")
    }
}

/// iOS: a start during an idle shutdown boots it again; a boot that fails shuts its simulator down.
extension IOSRuntimeOnAStandIn {
    /// Idle, it's shut down (here a slow `simctl shutdown`): a start meanwhile isn't told it runs, it boots again once
    /// the shutdown is through, and ticks meanwhile ask for no second shutdown.
    @Test(.timeLimit(.minutes(1))) func aStartDuringAnIdleShutdownBootsAgain() async throws {
        let (vm, folder) = try iOS(simctl: #"case "$2" in shutdown) sleep 1 ;; esac"#)
        defer { putAway(folder) }
        vm.exitProcess = {}
        #expect(await askIOS(vm, .start) == nil)
        vm.now = { Date() + Runtime.sleepAfter + 1 }
        vm.tick()
        vm.tick()
        #expect(vm.state == .off, "off from when it's asked")
        #expect(await askIOS(vm, .start) == nil)
        #expect(vm.state == .running)
        let calls = try xcrunCalls(folder)
        #expect(calls.filter { $0.hasPrefix("simctl shutdown") }.count == 1)
        #expect(calls.filter { $0.hasPrefix("simctl boot ") }.count == 2, "booted again after the shutdown")
        #expect(
            calls.lastIndex { $0.hasPrefix("simctl shutdown") } ?? 0 < calls.lastIndex { $0.hasPrefix("simctl boot ") }
                ?? 0)
        _ = await askIOS(vm, .stop)
    }

    /// A boot that fails (here its runner isn't built) shuts down the simulator it booted.
    @Test(.timeLimit(.minutes(1))) func aFailedBootShutsTheSimulatorDown() async throws {
        let (vm, folder) = try iOS(built: false)
        defer { putAway(folder) }
        #expect(await askIOS(vm, .start)?.contains("isn't built") == true)
        #expect(try await waitFor(5) { try xcrunCalls(folder).contains { $0.hasPrefix("simctl shutdown") } })
    }
}

private func boots(_ sdk: URL) throws -> Int {
    try String(contentsOf: sdk.appendingPathComponent("starts.log"), encoding: .utf8).split(separator: "\n").count
}

@MainActor private func askIOS(_ vm: IOSRuntime, _ op: VMHelper.Request.Operation) async -> String? {
    await withCheckedContinuation { c in vm.handle(.init(op: op)) { c.resume(returning: $0) } }
}

private func xcrunCalls(_ folder: URL) throws -> [String] {
    try String(contentsOf: folder.appendingPathComponent("xcrun.log"), encoding: .utf8).split(separator: "\n").map(
        String.init)
}
