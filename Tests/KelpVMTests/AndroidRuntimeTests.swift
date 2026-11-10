import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// The Android runtime on a stand-in SDK, one test at a time: each names its SDK by ANDROID_HOME, the process's own.
@MainActor @Suite(.serialized) struct AndroidRuntimeOnAStandIn {
    /// Which boots of the emulator have its window, step by step: Show asks it of the boot to come (off, headless, being
    /// slept), never of one up with it; whatever ends a shown emulator (`kelp vm sleep`, the memory budget's) takes it
    /// with it. An SDK of two scripts stands in for the emulator and adb; each row is a fresh machine.
    @Test(.timeLimit(.minutes(2))) func whichBootsHaveTheWindow() async throws {
        enum Step { case ask(VMHelper.Request.Operation), begin(show: Bool), sleepThenShow }
        let rows: [(steps: [Step], windows: [Bool], why: String)] = [
            (
                [.ask(.start), .ask(.show), .ask(.show), .ask(.sleep), .ask(.start)], [false, true, false],
                "an agent's headless boot, Show (twice), slept: the next agent's run is headless"
            ),
            (
                [.ask(.show), .ask(.sleep), .ask(.start)], [true, false],
                "Show from off boots with it; a sleep takes it"
            ),
            (
                [.begin(show: true), .ask(.show), .ask(.sleep), .ask(.start)], [true, false],
                "kelpd's Show: begin with the window, then show finds it up"
            ),
            (
                [.begin(show: false), .ask(.show)], [false, true],
                "an agent's begin, then Show: slept and booted again with it"
            ),
            (
                [.ask(.start), .begin(show: true), .ask(.sleep), .ask(.start)], [false, false],
                "a begin with the window on one up headless asks no later boot of it (Show does that)"
            ),
            (
                [.ask(.show), .sleepThenShow, .ask(.start)], [true, true],
                "Show while a shown one is being slept: back with it"
            ),
            ([.ask(.start), .sleepThenShow], [false, true], "Show while a headless one is being slept: back with it")
        ]
        // ANDROID_HOME names each row's SDK while it runs (KelpVMTests run in a process of their own); a developer's own is put back.
        let before = ProcessInfo.processInfo.environment["ANDROID_HOME"]
        defer { if let before { setenv("ANDROID_HOME", before, 1) } else { unsetenv("ANDROID_HOME") } }
        for row in rows {
            let (vm, sdk) = try standIn()
            defer { try? FileManager.default.removeItem(at: sdk) }
            let log = sdk.appendingPathComponent("starts.log").path
            func ask(_ r: VMHelper.Request) async -> String? {
                await withCheckedContinuation { c in vm.handle(r) { c.resume(returning: $0) } }
            }
            for step in row.steps {
                switch step {
                case .ask(let op): #expect(await ask(.init(op: op)) == nil, "\(row.why)")
                case .begin(let show):
                    _ = await ask(.begin(show: show))
                    _ = await ask(.init(op: .start))
                case .sleepThenShow:
                    vm.handle(.init(op: .sleep)) { _ in }   // not waited for: Show comes while it saves
                    #expect(await ask(.init(op: .show)) == nil, "\(row.why)")
                }
            }
            let boots = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map {
                !$0.contains("-no-window")
            }
            #expect(boots == row.windows, "\(row.why)")
            _ = await ask(.init(op: .sleep))
        }
    }

    /// A quit before a new size leaves an emulator that's up alone, as a Linux machine's kelp-vm does: a command may
    /// have woken it since kelpd looked.
    @Test(.timeLimit(.minutes(1))) func aQuitForANewSizeLeavesOneThatsUp() async throws {
        let before = ProcessInfo.processInfo.environment["ANDROID_HOME"]
        defer { if let before { setenv("ANDROID_HOME", before, 1) } else { unsetenv("ANDROID_HOME") } }
        let (vm, sdk) = try standIn()
        defer { try? FileManager.default.removeItem(at: sdk) }
        func ask(_ r: VMHelper.Request) async -> String? {
            await withCheckedContinuation { c in vm.handle(r) { c.resume(returning: $0) } }
        }
        var ended = false
        vm.exitProcess = { ended = true }
        #expect(await ask(.init(op: .start)) == nil)
        #expect(await ask(.quitIfDown)?.contains("in use") == true)
        #expect(vm.state == .running && !ended)
        _ = await ask(.init(op: .sleep))
    }

    /// SIGTERM leaves no emulator behind: one up is slept, one booting once it's up, one being saved once it's saved; and
    /// nothing new starts meanwhile (a start then would boot an emulator nobody ends).
    @Test(.timeLimit(.minutes(1))) func leavingEndsTheEmulatorWhateverItWasDoing() async throws {
        let before = ProcessInfo.processInfo.environment["ANDROID_HOME"]
        defer { if let before { setenv("ANDROID_HOME", before, 1) } else { unsetenv("ANDROID_HOME") } }
        enum When { case up, booting, saving }
        for when in [When.up, .booting, .saving] {
            let (vm, sdk) = try standIn()
            defer { try? FileManager.default.removeItem(at: sdk) }
            func ask(_ op: VMHelper.Request.Operation) async -> String? {
                await withCheckedContinuation { c in vm.handle(.init(op: op)) { c.resume(returning: $0) } }
            }
            await withCheckedContinuation { (gone: CheckedContinuation<Void, Never>) in
                vm.exitProcess = { gone.resume() }
                switch when {
                case .up:
                    Task {
                        _ = await ask(.start)
                        vm.leave()
                    }
                case .booting:
                    vm.handle(.init(op: .start)) { _ in }
                    vm.leave()
                case .saving:
                    Task {
                        _ = await ask(.start)
                        vm.handle(.init(op: .sleep)) { _ in }
                        vm.leave()
                    }
                }
            }
            // Its emulator was ended by `emu kill` (which takes its pid file), not left booting: it had started (the log)
            // and, a moment on, is still gone.
            #expect(
                try await waitFor(5) {
                    FileManager.default.fileExists(atPath: sdk.appendingPathComponent("starts.log").path)
                })
            try await Task.sleep(for: .milliseconds(500))
            #expect(!FileManager.default.fileExists(atPath: sdk.appendingPathComponent("emulator.pid").path), "\(when)")
            #expect(await ask(.start)?.contains("stopping") == true, "\(when): nothing starts once it's leaving")
        }
    }
}

/// A machine of its own on an SDK of two scripts, named by ANDROID_HOME: the emulator writes how it was started to the
/// log and runs until adb's `emu kill` (which writes its snapshot); adb writes what it was asked to adb.log, and answers Android booted once this
/// boot's emulator is there to kill (the pid of the one before goes with it). `booting` runs before the emulator does
/// (`exit` there: one that quits as it starts); `adb` answers first what it names (`*getprop*) ;;`: never booted).
@MainActor func standIn(booting: String = "", adb: String = "") throws -> (AndroidRuntime, URL) {
    let sdk = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString.prefix(6))")
    let log = sdk.appendingPathComponent("starts.log").path, pid = sdk.appendingPathComponent("emulator.pid").path
    let asked = sdk.appendingPathComponent("adb.log").path
    let saved = sdk.appendingPathComponent("machine/avd/phone.avd/snapshots/default_boot").path
    try script(
        sdk.appendingPathComponent("emulator/emulator"),
        """
        echo "$*" >> '\(log)'; \(booting)
        echo $$ > '\(pid)'; exec sleep 60
        """)
    try script(
        sdk.appendingPathComponent("platform-tools/adb"),
        """
        echo "$*" >> '\(asked)'
        case "$*" in \(adb) *getprop*) [ -s '\(pid)' ] && echo 1 ;; *"emu kill"*) kill "$(cat '\(pid)')"; rm -f '\(pid)'; mkdir -p '\(saved)'; touch '\(saved)/snapshot.pb' ;; esac
        """)
    setenv("ANDROID_HOME", sdk.path, 1)
    let folder = sdk.appendingPathComponent("machine")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let vm = AndroidRuntime(
        folder: folder,
        machine: VMMachine(
            name: "phone", os: "android", image: "i", cpus: 2, memoryMiB: 2048,
            diskGiB: 8, user: "u"))
    return (vm, sdk)
}

/// A machine's commands count as its use whoever runs them: a program of those named, naming the machine. bash stands
/// in for adb (a copy of a system program is killed as it starts, a link takes its target's name).
@MainActor @Test func aMachinesClientsAreTheProgramsNamingIt() async throws {
    let serial = "emulator-\(Int.random(in: 6000...6998) / 2 * 2)"
    let wait = #"sleep 30 & trap "kill $!" TERM; wait"#   // a TERM to bash ends its sleep too: nothing left behind
    #expect(Usage.clients(of: serial, programs: ["bash"]) == 0)
    let own = try Process.run(URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", wait, "-s", serial])
    defer { own.terminate() }
    #expect(Usage.clients(of: serial, programs: ["bash"]) == 0, "kelp-vm's own (its child) isn't a client")
    // Another's: started from a shell that's gone at once (launchd its parent then), its pid printed.
    let out = Pipe(), sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", "/bin/bash -c '\(wait)' -s \(serial) </dev/null >/dev/null 2>&1 & echo $!"]
    sh.standardOutput = out
    try sh.run()
    sh.waitUntilExit()
    let theirs = try #require(
        pid_t(
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(theirs, SIGTERM) }
    var seen = 0   // once it has started
    try await waitFor(2) {
        seen = Usage.clients(of: serial, programs: ["bash"])
        return seen != 0
    }
    #expect(seen == 1)
    #expect(
        Usage.clients(of: serial + "0", programs: ["bash"]) == 0 && Usage.clients(of: serial, programs: ["adb"]) == 0)
}

func script(_ url: URL, _ body: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
