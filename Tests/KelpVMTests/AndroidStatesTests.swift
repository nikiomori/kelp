import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// The Android runtime's states on the stand-in SDK, its clock moved past the idle limits: in the serialized suite, as
/// each names its SDK by ANDROID_HOME.
extension AndroidRuntimeOnAStandIn {
    /// Idle past `pauseAfter`, its CPU stops (`emu avd stop`); a start goes on from there (`emu avd start`), the same
    /// emulator.
    @Test(.timeLimit(.minutes(1))) func idleItPausesAndAStartGoesOn() async throws {
        let (vm, sdk, putAway) = try android()
        defer { putAway() }
        #expect(await ask(vm, .start) == nil)
        #expect(vm.state == .running)
        vm.now = { Date() + Runtime.pauseAfter + 1 }
        vm.tick()
        #expect(try await waitFor(5) { vm.state == .paused })
        #expect(try asked(sdk).contains("emu avd stop"))
        #expect(await ask(vm, .start) == nil)
        #expect(vm.state == .running)
        #expect(try asked(sdk).contains("emu avd start"))
        #expect(try boots(sdk) == 1, "woken from its pause, not booted again")
    }

    /// Paused past `sleepAfter`, it saves its snapshot and quits: asleep, no emulator left; the next start boots again.
    @Test(.timeLimit(.minutes(1))) func pausedLongItSleepsAndTheNextStartBoots() async throws {
        let (vm, sdk, putAway) = try android()
        defer { putAway() }
        #expect(await ask(vm, .start) == nil)
        vm.now = { Date() + Runtime.pauseAfter + 1 }
        vm.tick()
        #expect(try await waitFor(5) { vm.state == .paused })
        let pid = try emulatorPid(sdk)
        vm.now = { Date() + Runtime.sleepAfter + 1 }
        vm.tick()
        #expect(try await waitFor(10) { vm.state == .sleeping })
        #expect(try asked(sdk).contains("emu kill"))
        #expect(try await waitFor(5) { kill(pid, 0) != 0 }, "its emulator is gone")
        #expect(await ask(vm, .start) == nil)
        #expect(vm.state == .running)
        #expect(try boots(sdk) == 2)
    }

    /// A start that comes while the pause is under way is answered running: it goes on, not paused under that command.
    @Test(.timeLimit(.minutes(1))) func aStartWhileItPausesKeepsItRunning() async throws {
        let (vm, sdk, putAway) = try android(adb: #"*"avd stop"*) sleep 0.5 ;;"#)
        defer { putAway() }
        #expect(await ask(vm, .start) == nil)
        vm.now = { Date() + Runtime.pauseAfter + 1 }
        vm.tick()   // `emu avd stop` takes half a second
        #expect(await ask(vm, .start) == nil)
        #expect(try await waitFor(5) { try asked(sdk).contains("emu avd start") })
        #expect(vm.state == .running)
    }

    /// An emulator that quits as it boots fails the start that waited, and leaves the machine where the next start
    /// boots it again.
    @Test(.timeLimit(.minutes(1))) func anEmulatorThatQuitsAsItBootsCanBeStartedAgain() async throws {
        let once = #"[ -e "$ANDROID_AVD_HOME.quit" ] || { touch "$ANDROID_AVD_HOME.quit"; exit 1; }"#
        let (vm, sdk, putAway) = try android(booting: once)
        defer { putAway() }
        #expect(await ask(vm, .start)?.contains("quit") == true)
        #expect(try await waitFor(5) { vm.state == .off })
        #expect(await ask(vm, .start) == nil)
        #expect(vm.state == .running)
        #expect(try boots(sdk) == 2)
    }

    /// A boot that never finishes fails once its time is up, and its emulator is ended with it: none left holding the
    /// AVD.
    @Test(.timeLimit(.minutes(1))) func aBootThatNeverFinishesEndsItsEmulator() async throws {
        let (vm, sdk, putAway) = try android(adb: "*getprop*) ;;")
        defer { putAway() }
        let answer = Task { await ask(vm, .start) }
        #expect(try await waitFor(5) { (try? emulatorPid(sdk)) != nil })
        let pid = try emulatorPid(sdk)
        #expect(vm.state == .starting)
        vm.now = { Date() + 601 }   // a first boot's ten minutes
        #expect(await answer.value?.contains("didn't finish booting") == true)
        #expect(try await waitFor(5) { kill(pid, 0) != 0 }, "its emulator was ended")
        #expect(try await waitFor(5) { vm.state == .off })
    }

    /// A stop quits the emulator and forgets its snapshot (the next start boots afresh), then kelp-vm ends; a machine
    /// with a snapshot starts out asleep.
    @Test(.timeLimit(.minutes(1))) func aStopForgetsTheSnapshot() async throws {
        let (vm, sdk, putAway) = try android()
        defer { putAway() }
        let snapshot = vm.folder.appendingPathComponent("avd/phone.avd/snapshots/default_boot")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        #expect(AndroidRuntime(folder: vm.folder, machine: vm.machine).state == .sleeping)
        #expect(await ask(vm, .start) == nil)
        let pid = try emulatorPid(sdk)
        var ended = false
        vm.exitProcess = { ended = true }
        #expect(await ask(vm, .stop) == nil)
        #expect(ended && vm.state == .off)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try await waitFor(5) { kill(pid, 0) != 0 })
        #expect(AndroidRuntime(folder: vm.folder, machine: vm.machine).state == .off)
    }
}

/// A stand-in machine, and how to put it away: its emulator ended, its SDK removed, ANDROID_HOME as it was.
@MainActor private func android(booting: String = "", adb: String = "") throws -> (AndroidRuntime, URL, () -> Void) {
    let before = ProcessInfo.processInfo.environment["ANDROID_HOME"]
    let (vm, sdk) = try standIn(booting: booting, adb: adb)
    return (
        vm, sdk,
        {
            // still ours: not a number some other process has since
            if let pid = try? emulatorPid(sdk), Subprocess.parent(pid) == getpid() { kill(pid, SIGTERM) }
            if let before { setenv("ANDROID_HOME", before, 1) } else { unsetenv("ANDROID_HOME") }
            try? FileManager.default.removeItem(at: sdk)
        }
    )
}

@MainActor private func ask(_ vm: AndroidRuntime, _ op: VMHelper.Request.Operation) async -> String? {
    await withCheckedContinuation { c in vm.handle(.init(op: op)) { c.resume(returning: $0) } }
}

private func asked(_ sdk: URL) throws -> String {
    try String(contentsOf: sdk.appendingPathComponent("adb.log"), encoding: .utf8)
}

private func boots(_ sdk: URL) throws -> Int {
    try String(contentsOf: sdk.appendingPathComponent("starts.log"), encoding: .utf8).split(separator: "\n").count
}

private func emulatorPid(_ sdk: URL) throws -> pid_t {
    let text = try String(contentsOf: sdk.appendingPathComponent("emulator.pid"), encoding: .utf8)
    return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
}
