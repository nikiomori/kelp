import Agents
import Core
import Foundation
import os

/// What one kelpd hands the next when an update replaces it (`daemon.upgrade`): the socket, the home's lock and each
/// running session's terminal, all left open across exec in the same process. The programs stay this process's children
/// and never notice; what they print meanwhile waits in their terminals.
public struct Handover: Codable, Sendable {
    /// One running session. `modes` and `bytes` give its history: the last `bytes` of its log, in those terminal modes.
    /// `pending` is text sent that waits for the agent to be ready (a launch prompt, a send while a question is open),
    /// which the next kelpd types.
    struct Session: Codable, Sendable {
        var id: String, pid: Int32, fd: Int32, modes: String, bytes: Int
        var pending: [Prompt]?
        var status: Status?
        var reports: [String]?
    }
    struct Prompt: Codable, Sendable { var text: String, draft: Bool, paste: Bool }
    /// What a session's status and typing depend on, apart from its record: the session's whole `Kept` value. Its
    /// fields are encoded next to `hooked` (from the status detector), as earlier kelpds wrote them one by one.
    struct Status: Codable, Sendable {
        var kept: LiveSession.Kept
        var hooked: Bool?
        /// Whether the hand-over has `pasteMode`. When a kelpd from before that field wrote it, the session's terminal
        /// modes tell instead.
        var saysPasteMode = true

        private enum CodingKeys: String, CodingKey { case hooked, pasteMode }

        init(kept: LiveSession.Kept, hooked: Bool) {
            self.kept = kept
            self.hooked = hooked
        }

        init(from decoder: Decoder) throws {
            kept = try LiveSession.Kept(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hooked = try container.decodeIfPresent(Bool.self, forKey: .hooked)
            saysPasteMode = container.contains(.pasteMode)
        }

        func encode(to encoder: Encoder) throws {
            try kept.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(hooked, forKey: .hooked)
        }
    }
    var socket: Int32, lock: Int32
    var sessions: [Session]
    // A newer kelpd reads what an older one wrote: fields are only ever added, as optionals.

    /// What `kelpd --can-adopt` prints. With it, the kelpd about to be exec'd into says that it runs here and reads
    /// this hand-over, before any session is given up. A kelpd that can't (another architecture, a broken signature, a
    /// kelpd from before the flag) prints something else or nothing.
    public static let canAdopt = "kelpd adopts handover 1"
    static let storeFile = "kelp.sqlite"

    /// The answer `kelpd --can-adopt` gives in `root`. It is `canAdopt` when there is no store there, or when the store
    /// (`adoptable`'s copy) opens and migrates. Otherwise it says why not.
    public static func canAdopt(root: URL) -> (ok: Bool, said: String) {
        let path = root.appendingPathComponent(storeFile).path
        guard FileManager.default.fileExists(atPath: path) else { return (true, canAdopt) }
        do {
            _ = try Store(path: path)
            return (true, canAdopt)
        } catch {
            return (false, "kelpd can't open the store it would take over: \(error)")
        }
    }

    /// Whether the kelpd at `executable` takes sessions over (`canAdopt`), found by running it in a home of its own. A
    /// kelpd from before the flag starts as a daemon there instead, touching nothing of this daemon's (its store, its
    /// lock), and is stopped at the time limit. `home` is where that scratch home is made. `store` puts a copy of this
    /// daemon's store there, which the new kelpd opens and migrates as it would after the exec. A kelpd that can't is
    /// refused here, while every agent can still go on, not after the exec, which would end them all. It is asked in an
    /// empty home first, because a kelpd from before the flag mustn't start on a copy of the user's sessions.
    static func adoptable(_ executable: String, home: URL, store: (_ copy: URL) throws -> Void = { _ in }) -> Bool {
        let scratch = home.appendingPathComponent("adopt-check-\(getpid())")
        defer {
            Log.start.attempt("removing the adopt check's home") { try FileManager.default.removeItem(at: scratch) }
        }
        func answers() -> Bool {
            guard
                let result = Log.start.attempt(
                    "asking \(executable) whether it adopts",
                    {
                        try Subprocess.run(
                            [executable, "--can-adopt"], cwd: "/", env: ["KELP_HOME": scratch.path], timeLimit: 30)
                    })
            else { return false }
            if result.status != 0 {
                let said = String(decoding: result.stderr, as: UTF8.self)
                Log.start.error("\(executable, privacy: .public) can't adopt: \(said, privacy: .public)")
            }
            return result.status == 0
                && String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    == canAdopt
        }
        return Log.start.attempt("making the adopt check's home", { try Paths.ensure(scratch) }) != nil && answers()
            && Log.start.attempt(
                "copying the store for the adopt check", { try store(scratch.appendingPathComponent(storeFile)) })
                != nil
            && answers()
    }

    /// Reads and removes the file `kelpd --adopt` names. Returns nil if it can't be read; then the lock this process
    /// still holds makes the start fail, and the sessions end with it, as after a crash.
    public static func take(_ path: String) -> Handover? {
        defer { unlink(path) }
        do { return try JSONDecoder().decode(Handover.self, from: Data(contentsOf: URL(fileURLWithPath: path))) } catch
        {
            Log.start.fault("couldn't read what the last kelpd handed over: \(error)")
            return nil
        }
    }

    /// Reaps what the kelpd before this one still ran besides the sessions (a git, a language server it was stopping).
    /// Those are this process's children now, so each is reaped when it ends instead of staying a zombie. Call it
    /// before this run starts a program of its own, because that program's exit is for its runner to read.
    public func reapOthers() {
        let kept = Set(sessions.map(\.pid))
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(0, count)) where !kept.contains(pid) {
            Thread.detachNewThread {
                var st: Int32 = 0
                while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            }
        }
    }

    /// Execs `exe --adopt file` in place (`POSIX_SPAWN_SETEXEC`), keeping the same process, pid and children. Of its
    /// files, only stdio and the hand-over's stay open. Returns only by throwing.
    func exec(_ exe: String, file: String) throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        for fd in [0, 1, 2, socket, lock] + sessions.map(\.fd) { posix_spawn_file_actions_addinherit_np(&fa, fd) }
        let args: [String] = [exe, "--adopt", file]
        let argv = (args.map { strdup($0) } + [nil]) as [UnsafeMutablePointer<CChar>?]
        let env =
            (ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") } + [nil])
            as [UnsafeMutablePointer<CChar>?]
        defer { (argv + env).forEach { free($0) } }
        let rc = posix_spawn(nil, exe, &fa, &attr, argv, env)
        throw RPCError.internalError("couldn't run \(exe): \(String(cString: strerror(rc)))")
    }
}
