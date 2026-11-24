import Core
import Foundation
import TestSupport
import Testing

@testable import KelpVM

/// What each runtime answers to every request kelpd sends, from each state a test can bring it to, and where that
/// leaves it: what the shared dispatch (`Lifecycle.handle`) must keep. Each row is a fresh machine on its stand-in.
enum Asked: CustomStringConvertible {
    case status, start, begin, sleep, sleepIfIdle, stop, share, screen, show, quit, quitIfDown
    var request: VMHelper.Request {
        switch self {
        case .status: .init(op: .status)
        case .start: .init(op: .start)
        case .begin: .begin(show: false)
        case .sleep: .init(op: .sleep)
        case .sleepIfIdle: .sleepIfIdle
        case .stop: .init(op: .stop)
        case .share: .init(op: .share)
        case .screen: .init(op: .screen)
        case .show: .init(op: .show)
        case .quit: .init(op: .quit)
        case .quitIfDown: .quitIfDown
        }
    }
    var description: String { "\(request.op)\(request.args.map { " \($0)" } ?? "")" }
}

/// An answer: none (done), one that says this, or any failure.
enum Answer {
    case done, says(String), fails
    func fits(_ error: String?) -> Bool {
        switch self {
        case .done: error == nil
        case .says(let words): error?.contains(words) == true
        case .fails: error?.isEmpty == false
        }
    }
}

/// One turn of the main queue: what a reply's turn put after itself (`Runtime.leaveSoon`) has run.
@MainActor func aTurnLater() async { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }

extension AndroidRuntimeOnAStandIn {
    @Test(.timeLimit(minutes: 4)) func androidAnswersEveryRequestFromEachState() async throws {
        enum From { case off, running, paused, sleeping }
        let inUse = "in use again", noFolders = "shares no folders", notMine = "kelpd's to drive"
        let rows: [(From, Asked, Answer, VMState, exits: Bool)] = [
            (.off, .status, .done, .off, false), (.off, .start, .done, .running, false),
            (.off, .begin, .done, .running, false), (.off, .sleep, .done, .off, false),
            (.off, .sleepIfIdle, .done, .off, false), (.off, .stop, .done, .off, true),
            (.off, .share, .says(noFolders), .off, false), (.off, .screen, .says(notMine), .off, false),
            (.off, .show, .done, .running, false), (.off, .quit, .done, .off, true),
            (.off, .quitIfDown, .done, .off, true),
            (.running, .status, .done, .running, false), (.running, .start, .done, .running, false),
            (.running, .begin, .done, .running, false), (.running, .sleep, .done, .sleeping, false),
            (.running, .sleepIfIdle, .says("is in use."), .running, false), (.running, .stop, .done, .off, true),
            (.running, .share, .says(noFolders), .running, false),
            (.running, .screen, .says(notMine), .running, false), (.running, .show, .done, .running, false),
            (.running, .quit, .done, .off, true), (.running, .quitIfDown, .says(inUse), .running, false),
            (.paused, .status, .done, .paused, false), (.paused, .start, .done, .running, false),
            (.paused, .begin, .done, .running, false), (.paused, .sleep, .done, .sleeping, false),
            (.paused, .sleepIfIdle, .done, .sleeping, false), (.paused, .stop, .done, .off, true),
            (.paused, .share, .says(noFolders), .paused, false), (.paused, .screen, .says(notMine), .paused, false),
            (.paused, .show, .done, .running, false), (.paused, .quit, .done, .off, true),
            (.paused, .quitIfDown, .says(inUse), .paused, false),
            (.sleeping, .status, .done, .sleeping, false), (.sleeping, .start, .done, .running, false),
            (.sleeping, .begin, .done, .running, false), (.sleeping, .sleep, .done, .sleeping, false),
            (.sleeping, .sleepIfIdle, .done, .sleeping, false), (.sleeping, .stop, .done, .off, true),
            (.sleeping, .share, .says(noFolders), .sleeping, false),
            (.sleeping, .screen, .says(notMine), .sleeping, false), (.sleeping, .show, .done, .running, false),
            (.sleeping, .quit, .done, .off, true), (.sleeping, .quitIfDown, .done, .off, true)
        ]
        for (from, asked, answer, state, exits) in rows {
            let (vm, _, putAway) = try androidStandIn()
            defer { putAway() }
            var ended = false
            vm.exitProcess = { ended = true }
            switch from {
            case .off: break
            case .running: _ = await askAndroid(vm, .init(op: .start))
            case .paused:
                _ = await askAndroid(vm, .init(op: .start))
                vm.now = { Date() + Runtime.pauseAfter + 1 }
                vm.tick()
                try #require(try await waitFor(5) { vm.state == .paused }, "\(from)")
            case .sleeping:
                _ = await askAndroid(vm, .init(op: .start))
                _ = await askAndroid(vm, .init(op: .sleep))
            }
            let row = "\(from), \(asked)"
            #expect(vm.state == "\(from)".vmState, "\(row): set up")
            let said = await askAndroid(vm, asked.request)
            #expect(answer.fits(said), "\(row): said \(said ?? "nothing")")
            #expect(try await waitFor(5) { vm.state == state }, "\(row): \(vm.state), not \(state)")
            if exits { #expect(try await waitFor(5) { ended }, "\(row): kelp-vm ends") }
            await aTurnLater()
            #expect(ended == exits, "\(row): ended \(ended)")
            if !exits { _ = await askAndroid(vm, .init(op: .stop)) }   // its emulator quit before the SDK goes
        }
    }
}

extension IOSRuntimeOnAStandIn {
    /// Show is left out: it opens the Mac's own Simulator app.
    @Test(.timeLimit(minutes: 3)) func iOSAnswersEveryRequestFromEachState() async throws {
        enum From { case off, starting, running }
        let rows: [(From, Asked, Answer, VMState, exits: Bool)] = [
            (.off, .status, .done, .off, false), (.off, .start, .done, .running, false),
            (.off, .begin, .done, .running, false), (.off, .sleep, .done, .off, true),
            (.off, .sleepIfIdle, .done, .off, true), (.off, .stop, .done, .off, true),
            (.off, .share, .says("shares no folders"), .off, false),
            (.off, .screen, .says("kelpd's to drive"), .off, false), (.off, .quit, .done, .off, true),
            (.off, .quitIfDown, .done, .off, true),
            (.running, .status, .done, .running, false), (.running, .start, .done, .running, false),
            (.running, .begin, .done, .running, false), (.running, .sleep, .done, .off, true),
            // the start that brought it up is a runner call under way (`callWindow`)
            (.running, .sleepIfIdle, .says("is in use."), .running, false), (.running, .stop, .done, .off, true),
            (.running, .share, .says("shares no folders"), .running, false),
            (.running, .screen, .says("kelpd's to drive"), .running, false), (.running, .quit, .done, .off, true),
            (.running, .quitIfDown, .says("in use again"), .running, false),
            // its simulator still booting (a slow bootstatus): what doesn't stop it waits, or is answered at once
            (.starting, .status, .done, .running, false), (.starting, .start, .done, .running, false),
            (.starting, .begin, .done, .running, false), (.starting, .sleep, .done, .off, true),
            (.starting, .sleepIfIdle, .done, .running, false), (.starting, .stop, .done, .off, true),
            (.starting, .share, .says("shares no folders"), .running, false),
            (.starting, .screen, .says("kelpd's to drive"), .running, false), (.starting, .quit, .done, .off, true),
            (.starting, .quitIfDown, .says("in use again"), .running, false)
        ]
        for (from, asked, answer, state, exits) in rows {
            let (vm, folder) = try iOS(simctl: from == .starting ? #"[ "$2" = bootstatus ] && sleep 1"# : "")
            defer { putAway(folder) }
            var ended = false
            vm.exitProcess = { ended = true }
            func ask(_ request: VMHelper.Request) async -> String? {
                await withCheckedContinuation { c in vm.handle(request) { c.resume(returning: $0) } }
            }
            var booting: Task<String?, Never>?
            switch from {
            case .off: break
            case .running: _ = await ask(.init(op: .start))
            case .starting:
                booting = Task { await ask(.init(op: .start)) }
                let log = folder.appendingPathComponent("xcrun.log")
                try #require(try await waitFor(5) { String(contentsIfAny: log)?.contains("bootstatus") == true })
            }
            let row = "\(from), \(asked)"
            #expect(vm.state == "\(from)".vmState, "\(row): set up")
            let said = await ask(asked.request)
            #expect(answer.fits(said), "\(row): said \(said ?? "nothing")")
            #expect(try await waitFor(5) { vm.state == state }, "\(row): \(vm.state), not \(state)")
            if exits { #expect(try await waitFor(5) { ended }, "\(row): kelp-vm ends") }
            await aTurnLater()
            #expect(ended == exits, "\(row): ended \(ended)")
            _ = await booting?.value   // answered: up, or told it was shut down
            if !exits {
                vm.exitProcess = {}
                _ = await ask(.init(op: .stop))
            }
        }
    }
}

/// A Linux machine with no disk (a boot fails before Virtualization runs anything): off, asleep (a saved state on
/// disk), or failed.
@MainActor @Test func aMachineWithoutAVMAnswersEveryRequestFromEachState() async throws {
    enum From { case off, sleeping, error }
    let rows: [(From, Asked, Answer, VMState, exits: Bool)] = [
        (.off, .status, .done, .off, false), (.off, .start, .fails, .error, false),
        (.off, .begin, .done, .error, false), (.off, .sleep, .done, .off, true),
        (.off, .sleepIfIdle, .done, .off, true), (.off, .stop, .done, .off, true),
        (.off, .share, .says("share: a path"), .off, false), (.off, .screen, .says("has no screen"), .off, false),
        (.off, .show, .fails, .error, false), (.off, .quit, .done, .off, true), (.off, .quitIfDown, .done, .off, true),
        (.sleeping, .status, .done, .sleeping, false), (.sleeping, .start, .fails, .error, false),
        (.sleeping, .begin, .done, .error, false), (.sleeping, .sleep, .done, .sleeping, true),
        (.sleeping, .sleepIfIdle, .done, .sleeping, true), (.sleeping, .stop, .done, .off, true),
        (.sleeping, .share, .says("share: a path"), .sleeping, false),
        (.sleeping, .screen, .says("has no screen"), .sleeping, false), (.sleeping, .show, .fails, .error, false),
        (.sleeping, .quit, .done, .sleeping, true), (.sleeping, .quitIfDown, .done, .sleeping, true),
        (.error, .status, .done, .error, false), (.error, .start, .fails, .error, false),
        (.error, .begin, .done, .error, false), (.error, .sleep, .done, .error, true),
        (.error, .sleepIfIdle, .done, .error, true), (.error, .stop, .done, .off, true),
        (.error, .share, .says("share: a path"), .error, false),
        (.error, .screen, .says("has no screen"), .error, false),
        (.error, .show, .fails, .error, false), (.error, .quit, .done, .error, true),
        (.error, .quitIfDown, .done, .error, true)
    ]
    for (from, asked, answer, state, exits) in rows {
        let folder = tmp().appendingPathComponent("vm-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let linux = VMMachine(name: "box", os: "linux", image: "i", cpus: 2, memoryMiB: 2048, diskGiB: 8, user: "u")
        try JSONEncoder().encode(linux).write(to: folder.appendingPathComponent("machine.json"))
        if from == .sleeping {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("state.vzsave").path, contents: nil)
        }
        let vm = try Runtime(folder: folder)
        var ended = false
        vm.exitProcess = { ended = true }
        func ask(_ request: VMHelper.Request) async -> String? {
            await withCheckedContinuation { c in vm.handle(request) { error, _ in c.resume(returning: error) } }
        }
        if from == .error { _ = await ask(.init(op: .start)) }
        let row = "\(from), \(asked)"
        #expect(vm.state == "\(from)".vmState, "\(row): set up")
        let said = await ask(asked.request)
        #expect(answer.fits(said), "\(row): said \(said ?? "nothing")")
        #expect(vm.state == state, "\(row): \(vm.state), not \(state)")
        await aTurnLater()
        #expect(ended == exits, "\(row): ended \(ended)")
    }
}

extension String {
    /// A row's "from" named as the state it sets up.
    fileprivate var vmState: VMState? { VMState(rawValue: self) }
}
