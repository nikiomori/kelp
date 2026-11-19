import Core
import Foundation
import os

/// Who is connected to the socket: each client, which of them are raw byte pipes (`kelp attach`), and which is Kelp's
/// window (with what it last said it shows). It has a lock of its own.
///
/// The daemon's lock order, outermost first: a session's wake lock (`Sessions.wakeLocks`; several can be taken, by id)
/// → `Sessions.live` → `Clients` → a session's own lock → a `Connection`'s lock. (A session's lock is never held while
/// another lock is taken: output, status and hooks call out afterwards.)
/// A JSON attach subscribes first and then asks `isConnected`. The reader's cleanup removes the client here first and
/// then detaches it from every session. Whichever order they run in, one of the two detaches it.
final class Clients: Sendable {
    private struct State {
        var all: [Int: Connection] = [:], next = 1
        var raw = Set<Int>()   // byte pipes, and new clients until a first request: they get no JSON events
        var app = Set<Int>()   // Kelp's window (ui.publish): it gets event.ui
        var muted = Set<Int>()   // asked for no broadcasts (client.events): kelp attach's control connection
        var uiState = ShownUI()   // what the app last published; cleared when no app is connected
        var replies: [String: Waiting] = [:]   // ui.browser requests the app hasn't answered
    }
    /// A request waiting for the app: the windows it went to (a window that hangs up can't answer it), and its timeout.
    private struct Waiting {
        let continuation: CheckedContinuation<JSONValue, Error>, to: Set<Int>
        var timer: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Adds a client that counts as raw until it asks for something (`kelp attach` sends `session.stream` first). An
    /// event broadcast before then would otherwise land in its byte stream, on the screen.
    func add(fd: Int32) -> Connection {
        let id = state.withLock { state in
            defer { state.next += 1 }
            return state.next
        }
        // This asks the system who connected, so it runs outside the lock that every event takes.
        let connection = Connection(id: id, fd: fd)
        state.withLock { state in
            state.all[id] = connection
            state.raw.insert(id)
        }
        return connection
    }

    /// Removes a client that hung up. It gets nothing more, and the app's published state is cleared when the last app
    /// goes.
    func remove(_ id: Int) {
        let orphans = state.withLock { state -> [Waiting] in
            state.all[id] = nil
            state.raw.remove(id)
            state.muted.remove(id)
            if state.app.remove(id) != nil, state.app.isEmpty { state.uiState = ShownUI() }
            // Requests sent only to windows that are gone now: nobody will answer them.
            let gone = state.replies.filter { $0.value.to.allSatisfy { state.all[$0] == nil } }
            for key in gone.keys { state.replies[key] = nil }
            return Array(gone.values)
        }
        for waiting in orphans {
            waiting.timer?.cancel()
            waiting.continuation.resume(throwing: RPCError.internalError("Kelp's window closed before it answered"))
        }
    }

    func everyone() -> [Connection] { state.withLock { Array($0.all.values) } }
    func peer(_ id: Int) -> String? { state.withLock { $0.all[id]?.peer } }
    func connection(_ id: Int) -> Connection? { state.withLock { $0.all[id] } }
    func setRaw(_ id: Int, _ on: Bool) { state.withLock { s in if on { s.raw.insert(id) } else { s.raw.remove(id) } } }

    /// `id` speaks JSON-RPC from now on, and hears events unless `muted`: both in one step, so no broadcast falls between.
    func speaksJSON(_ id: Int, muted: Bool) {
        state.withLock { state in
            state.raw.remove(id)
            if muted { state.muted.insert(id) }
        }
    }

    /// Whether `id` is still connected (see the note on attaching above).
    func isConnected(_ id: Int) -> Bool { state.withLock { $0.all[id] != nil } }

    /// Splits the subscribers of a session's output into the raw ones (sent bytes) and the rest (sent a JSON event).
    func split(_ subs: Set<Int>) -> (raw: [Connection], json: Set<Int>) {
        state.withLock { s in (subs.filter { s.raw.contains($0) }.compactMap { s.all[$0] }, subs.subtracting(s.raw)) }
    }

    /// Who gets a JSON event: everyone but the raw pipes and those that asked for none, or only those in `only`.
    func targets(_ only: Set<Int>?) -> [Connection] {
        state.withLock { state in
            state.all.filter { id, _ in
                !state.raw.contains(id) && (only.map { $0.contains(id) } ?? !state.muted.contains(id))
            }
            .map(\.value)
        }
    }

    /// Sends a JSON event to `targets(only)`, encoded once.
    func notify(_ event: some RPCEvent, to only: Set<Int>? = nil) {
        guard let line = try? Wire.line(RPCNotification(event)) else { return }
        targets(only).forEach { $0.send(line) }
    }

    func setMuted(_ id: Int, _ muted: Bool) {
        state.withLock { if muted { $0.muted.insert(id) } else { $0.muted.remove(id) } }
    }

    /// Waits for the answer to `request` from one of the windows in `apps` (`send` asks them). It throws once `seconds`
    /// pass without an answer, or once they've all hung up.
    func reply(to request: String, from apps: Set<Int>, within seconds: TimeInterval, send: () -> Void) async throws
        -> JSONValue
    {
        try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                self?.answer(request, .failure(RPCError.internalError("Kelp didn't answer in \(Int(seconds)) s")))
            }
            state.withLock { $0.replies[request] = Waiting(continuation: continuation, to: apps, timer: timer) }
            send()
        }
    }

    /// Delivers an answer to `request`. The first answer wins; a late one (after the timeout, or from a second window)
    /// finds nothing waiting.
    func answer(_ request: String, _ result: Result<JSONValue, Error>) {
        guard let waiting = state.withLock({ $0.replies.removeValue(forKey: request) }) else { return }
        waiting.timer?.cancel()
        waiting.continuation.resume(with: result)
    }

    func publishUI(_ ui: ShownUI, from id: Int) {
        state.withLock {
            $0.uiState = ui
            $0.app.insert(id)
        }
    }
    var uiState: ShownUI { state.withLock { $0.uiState } }
    var apps: Set<Int> { state.withLock { $0.app.subtracting($0.raw) } }
}

extension Clients {
    /// The path of KelpApp beside this daemon (in one bundle, or one build folder). KELP_APP_EXECUTABLE stands in for
    /// it in tests.
    static var appExecutable: String {
        #if DEBUG   // tests stand in for the app; a release build takes no word for it from whoever started kelpd
            if let executable = ProcessInfo.processInfo.environment["KELP_APP_EXECUTABLE"] {
                return URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            }
        #endif
        let me = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return me.deletingLastPathComponent().appendingPathComponent("KelpApp").resolvingSymlinksInPath().path
    }

    /// The path of a machine's kelp-vm, next to this daemon (`VMService.helper`). It is Kelp's own code, and the
    /// buttons in its window are pressed by the user.
    static var machineExecutable: String {
        let me = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return URL(fileURLWithPath: VMService.helper(beside: me.path)).resolvingSymlinksInPath().path
    }

    /// Refuses anyone but Kelp's window, for what only the window may do (its state, trusting a project). The log says
    /// who was refused, so a second install or a stale app (whose path isn't the one beside this daemon) can be told
    /// apart.
    func requireApp(_ conn: Int, _ refusal: String) throws {
        let peer = peer(conn)
        guard peer != Self.appExecutable else { return }
        Log.rpc.notice(
            "refused \(refusal, privacy: .public): \(peer ?? "an unknown program", privacy: .public) isn't \(Self.appExecutable, privacy: .public)"
        )
        throw RPCError.refused(refusal)
    }
}
