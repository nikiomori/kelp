import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// The iOS runtime on a stand-in xcrun: `simctl` writes what it was asked to xcrun.log, `xcodebuild` is Kelp's runner
/// (perl answering its ping on TEST_RUNNER_KELP_PORT, or one that quits). One at a time: each takes the first free port
/// from 8700.
@MainActor @Suite(.serialized) struct IOSRuntimeOnAStandIn {
    /// A start boots the simulator, starts the runner and waits for its answer; a stop ends both, then kelp-vm.
    @Test(.timeLimit(.minutes(1))) func aStartBootsTheSimulatorAndItsRunnerAndAStopEndsThem() async throws {
        let (vm, folder) = try iOS()
        defer { putAway(folder) }
        #expect(await ask(vm, .start) == nil)
        #expect(vm.state == .running)
        let calls = try asked(folder), id = try udid(folder)
        #expect(calls.contains("simctl boot \(id)") && calls.contains("simctl bootstatus \(id) -b"))
        #expect(calls.contains("xcodebuild test-without-building"))
        let runner = try runnerPid(folder)
        var ended = false
        vm.exitProcess = { ended = true }
        #expect(await ask(vm, .stop) == nil)
        #expect(ended && vm.state == .off)
        #expect(try asked(folder).contains("simctl shutdown \(id)"))
        #expect(try await waitFor(5) { kill(runner, 0) != 0 }, "no runner left")
    }

    /// A quit before a new size leaves a simulator that's up alone.
    @Test(.timeLimit(.minutes(1))) func aQuitForANewSizeLeavesOneThatsUp() async throws {
        let (vm, folder) = try iOS()
        defer { putAway(folder) }
        var ended = false
        vm.exitProcess = { ended = true }
        #expect(await ask(vm, .start) == nil)
        #expect(await withCheckedContinuation { c in vm.handle(.quitIfDown) { c.resume(returning: $0) } } != nil)
        #expect(vm.state == .running && !ended)
        vm.exitProcess = {}
        _ = await ask(vm, .stop)
    }

    /// A runner not built fails the start and says so; once it's there, the next start boots.
    @Test(.timeLimit(.minutes(1))) func aRunnerNotBuiltFailsTheStartAndTheNextOneRecovers() async throws {
        let (vm, folder) = try iOS(built: false)
        defer { putAway(folder) }
        #expect(await ask(vm, .start)?.contains("isn't built") == true)
        #expect(vm.state == .error)
        try build(folder)
        #expect(await ask(vm, .start) == nil)
        #expect(vm.state == .running)
        vm.exitProcess = {}
        _ = await ask(vm, .stop)
    }

    /// A runner that quits as it starts fails the start at once, not after its three minutes.
    @Test(.timeLimit(.minutes(1))) func aRunnerThatQuitsFailsTheStart() async throws {
        let (vm, folder) = try iOS(runner: "exit 3")
        defer { putAway(folder) }
        #expect(await ask(vm, .start)?.contains("runner quit") == true)
        #expect(vm.state == .error)
    }

    /// Unused for `sleepAfter` it shuts down (a simulator can't be paused) and kelp-vm stays, for the next start to
    /// boot.
    @Test(.timeLimit(.minutes(1))) func idleItShutsDownAndTheNextStartBoots() async throws {
        let (vm, folder) = try iOS()
        defer { putAway(folder) }
        var ended = false
        vm.exitProcess = { ended = true }
        #expect(await ask(vm, .start) == nil)
        let runner = try runnerPid(folder)
        vm.now = { Date() + Runtime.sleepAfter + 1 }
        vm.tick()
        #expect(try await waitFor(5) { vm.state == .off })
        #expect(try await waitFor(5) { try asked(folder).contains("simctl shutdown") }, "off at once, then shut down")
        #expect(try await waitFor(5) { kill(runner, 0) != 0 })
        #expect(!ended)
        #expect(await ask(vm, .start) == nil)
        #expect(vm.state == .running)
        _ = await ask(vm, .stop)
    }
}

/// A machine's folder with its simulator's udid (one no real program names), the runner built unless `built` is false,
/// and an xcrun of its own whose xcodebuild runs `runner`; `simctl` runs first for each call (`sleep 1` there: a slow
/// one).
@MainActor func iOS(built: Bool = true, runner: String? = nil, simctl: String = "") throws -> (IOSRuntime, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ios-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "U-\(UUID().uuidString)".write(to: folder.appendingPathComponent("udid"), atomically: true, encoding: .utf8)
    if built { try build(folder) }
    let log = folder.appendingPathComponent("xcrun.log").path, pid = folder.appendingPathComponent("runner.pid").path
    let answers =
        #"$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ENV{TEST_RUNNER_KELP_PORT}, "#
        + #"Listen => 5, ReuseAddr => 1) or die; "#
        + #"while ($c = $s->accept) { <$c>; print $c "{\"text\":\"ok\"}"; close $c }"#
    try script(
        folder.appendingPathComponent("xcrun"),
        """
        echo "$*" >> '\(log)'
        [ "$1" = simctl ] && { \(simctl.isEmpty ? ":" : simctl); }
        [ "$1" = xcodebuild ] || exit 0
        echo $$ > '\(pid)'
        \(runner ?? "exec /usr/bin/perl -MIO::Socket::INET -e '\(answers)'")
        """)
    let vm = IOSRuntime(
        folder: folder,
        machine: VMMachine(name: "phone", os: "ios", image: "i", cpus: 2, memoryMiB: 2048, diskGiB: 8, user: "u"))
    vm.xcrun = folder.appendingPathComponent("xcrun").path
    return (vm, folder)
}

/// Its runner ended, whatever the test left, and its folder removed.
func putAway(_ folder: URL) {
    // still ours: not a number some other process has since
    if let runner = try? runnerPid(folder), Subprocess.parent(runner) == getpid() { kill(runner, SIGTERM) }
    try? FileManager.default.removeItem(at: folder)
}

private func build(_ folder: URL) throws {
    let products = folder.appendingPathComponent("dd/Build/Products")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: products.appendingPathComponent("Runner.xctestrun").path, contents: nil)
}

@MainActor private func ask(_ vm: IOSRuntime, _ op: VMHelper.Request.Operation) async -> String? {
    await withCheckedContinuation { c in vm.handle(.init(op: op)) { c.resume(returning: $0) } }
}

private func asked(_ folder: URL) throws -> String {
    try String(contentsOf: folder.appendingPathComponent("xcrun.log"), encoding: .utf8)
}

private func udid(_ folder: URL) throws -> String {
    try String(contentsOf: folder.appendingPathComponent("udid"), encoding: .utf8)
}

private func runnerPid(_ folder: URL) throws -> pid_t {
    let text = try String(contentsOf: folder.appendingPathComponent("runner.pid"), encoding: .utf8)
    return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
}
