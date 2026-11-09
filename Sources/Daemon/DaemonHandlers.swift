import Core
import Foundation
import ServiceManagement

// daemon.*: ping, shutdown, upgrade, and whether it may run in the background: the daemon's own lifetime.

extension Ping: Handled {
    static var quick: Bool { true }
    func handle(_: NoService) throws -> String { "pong" }
}
extension DaemonShutdown: Handled {
    /// In order, as daemon.upgrade: the stop starts once its reply is queued, and the replies queued go out before
    /// anyone is hung up (`Daemon.answerInOrder`), not on a timer a busy machine could outrun.
    static var inOrder: Bool { true }
    func handle(_: NoService) throws -> Done { Done() }
}

extension DaemonUpgrade: Handled {
    /// Answered on the reader thread, its reply queued right after: the hand-over (which drains what's queued) starts
    /// once it is, not on a timer that a busy cooperative pool could outrun (`Daemon.serve`).
    static var inOrder: Bool { true }
    func handle(_ upgrade: Upgrade) throws -> Done {
        // Only kelpd itself: a daemon hosted in another program (the tests) would exec that program.
        guard URL(fileURLWithPath: upgrade.executable).lastPathComponent == "kelpd",
            FileManager.default.isExecutableFile(atPath: upgrade.executable)
        else {
            throw RPCError.invalidParams("no kelpd to upgrade to at \(upgrade.executable)")
        }
        if let why = upgrade.refused() { throw RPCError.invalidParams(why) }
        // Before the reply, so a refusal reaches the app as this call's error and it asks the user at once, instead of
        // reconnecting to a daemon that stayed. The app waits for this answer; only its own connection is held meanwhile.
        guard Subprocess.allowingPrograms(upgrade.adoptable) else {
            let why = "The new background service can't take the running sessions over."
            Upgrade.refuse(root: upgrade.root, executable: upgrade.executable, why)
            throw RPCError.invalidParams(why)
        }
        upgrade.waitIdle()   // a clone or a worktree being made finishes instead of losing its git mid-way
        return Done()
    }
}

/// daemon.upgrade's: the binary the daemon runs and its exec in place, nothing else of it.
struct Upgrade {
    let executable: String, root: URL
    /// Whether the kelpd at `executable` takes the sessions over (`Handover.adoptable`).
    var adoptable: () -> Bool = { true }
    /// Until no slow work is running (at most a few seconds).
    var waitIdle: () -> Void = {}
    let run: @Sendable () -> Void

    /// Why the binary now at `executable` was refused, as long as it's still that one (same modification time).
    func refused() -> String? {
        guard let data = FileManager.default.contents(atPath: Self.refusal(root).path) else { return nil }   // none refused
        let parts = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).map(String.init)
        return parts.count == 2 && Double(parts[0]) == Self.modified(executable) ? parts[1] : nil
    }
    static func refuse(root: URL, executable: String, _ why: String) {
        Log.start.attempt("keeping why the update was refused") {
            try "\(modified(executable))\n\(why)".write(to: refusal(root), atomically: true, encoding: .utf8)
        }
    }
    private static func refusal(_ root: URL) -> URL { root.appendingPathComponent("upgrade-refused") }
    /// When the file at `path` was last changed (seconds since 1970); 0 when there's none.
    static func modified(_ path: String) -> Double {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970
            ?? 0
    }
}

extension DaemonBackgroundAllowed: Handled {
    /// Off the reader: each `status` waits for the system. A kelpd outside an app (a build's) has no such switch.
    func handle(_: NoService) throws -> Bool {
        let app = Bundle.main.bundleURL, suffix = (Bundle.main.bundleIdentifier ?? "").dropFirst("dev.kelp.app".count)
        guard app.pathExtension == "app" else { return true }
        return SMAppService.agent(plistName: "dev.kelp.kelpd\(suffix).plist").status != .requiresApproval
    }
}
