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
    #expect(await ask(.sleep) == nil)   // `kelp vm sleep`, or the memory budget's: the window goes with it
    #expect(await ask(.start) == nil)   // the next agent's run
    let starts = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
    #expect(starts.count == 3)
    #expect(starts.first?.contains("-no-window") == true)
    #expect(starts.dropFirst().first?.contains("-no-window") == false, "Show's boot has its window")
    #expect(starts.last?.contains("-no-window") == true, "a sleep after Show takes the window with it")
    #expect(await ask(.sleep) == nil)
}

private func script(_ url: URL, _ body: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
