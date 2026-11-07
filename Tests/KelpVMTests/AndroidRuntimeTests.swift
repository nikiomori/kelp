import Core
import Foundation
import Testing
@testable import KelpVM

/// Show on an emulator an agent booted without its window sleeps it and boots it again with one: the first emulator's
/// end (the sleep's own) must not take back what Show asked. An SDK of two scripts stands in for the emulator and adb.
@MainActor @Test(.timeLimit(.minutes(1))) func showBootsAHeadlessEmulatorAgainWithItsWindow() async throws {
    let sdk = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString.prefix(6))")
    defer { try? FileManager.default.removeItem(at: sdk) }
    let log = sdk.appendingPathComponent("starts.log").path, pid = sdk.appendingPathComponent("emulator.pid").path
    try script(sdk.appendingPathComponent("emulator/emulator"), """
        echo "$*" >> '\(log)'; echo $$ > '\(pid)'; exec sleep 60
        """)
    try script(sdk.appendingPathComponent("platform-tools/adb"), """
        case "$*" in *getprop*) echo 1 ;; *"emu kill"*) kill "$(cat '\(pid)')" ;; esac
        """)
    // The only test here that reads it (KelpVMTests run in a process of their own); a developer's own is put back.
    let before = ProcessInfo.processInfo.environment["ANDROID_HOME"]
    setenv("ANDROID_HOME", sdk.path, 1)
    defer { if let before { setenv("ANDROID_HOME", before, 1) } else { unsetenv("ANDROID_HOME") } }
    let folder = sdk.appendingPathComponent("machine")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let vm = AndroidRuntime(folder: folder, machine: VMMachine(name: "phone", os: "android", image: "i", cpus: 2, memoryMiB: 2048,
                                                               diskGiB: 8, user: "u"))
    func ask(_ op: VMHelper.Request.Operation) async -> String? {
        await withCheckedContinuation { c in vm.handle(.init(op: op)) { c.resume(returning: $0) } }
    }
    #expect(await ask(.start) == nil)   // an agent's run: headless
    #expect(await ask(.show) == nil)
    #expect(await ask(.show) == nil)   // shown already: nothing to boot, nothing kept for a later one
    #expect(await ask(.show) == nil)
    #expect(await ask(.sleep) == nil)   // `kelp vm sleep`, or the memory budget's: the window goes with it
    #expect(await ask(.start) == nil)   // the next agent's run
    let starts = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
    #expect(starts.count == 3)
    #expect(starts.first?.contains("-no-window") == true)   // the agent's
    #expect(starts.dropFirst().first?.contains("-no-window") == false, "Show's boot has its window")
    #expect(starts.last?.contains("-no-window") == true, "a sleep after Show takes the window with it")
    #expect(await ask(.sleep) == nil)
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
    let theirs = try #require(pid_t(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(theirs, SIGTERM) }
    var seen = 0   // once it has started
    for _ in 0..<40 where seen == 0 {
        seen = Usage.clients(of: serial, programs: ["bash"])
        if seen == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    #expect(seen == 1)
    #expect(Usage.clients(of: serial + "0", programs: ["bash"]) == 0 && Usage.clients(of: serial, programs: ["adb"]) == 0)
}

private func script(_ url: URL, _ body: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
