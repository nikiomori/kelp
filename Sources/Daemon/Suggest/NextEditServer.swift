import Core
import Foundation
import os

/// The model that guesses the next edit, Sweep Next-Edit 1.5B (Apache-2.0), in a llama-server (llama.cpp) that kelpd
/// starts on a free port of its own: for the first ask, or Start. It stops after 15 minutes unasked, on a memory
/// warning, when the next edit is switched off, and with the daemon; a start that takes over 15 minutes is ended. The
/// first start downloads the model (1.5 GB) into llama.cpp's cache. Prompt lookup (ngram-simple) does it: the model writes the cursor's lines again, most of
/// it a copy of what it read, which this takes from the prompt, so an answer takes 0.36 s, not 1.5.
final class NextEditServer: Sendable {
    static let arguments = [
        "--hf-repo", "sweepai/sweep-next-edit-1.5B", "--hf-file", "sweep-next-edit-1.5b.q8_0.v2.gguf", "--host",
        "127.0.0.1", "-c", "8192", "-np", "1", "-ngl", "99", "--spec-type", "ngram-simple",
        "--spec-ngram-simple-size-n", "4", "--spec-ngram-simple-size-m", "32"
    ]
    /// An edit offered must be this sure of each token: on Kelp's history −0.5 kept a quarter of the answers, 43 % of
    /// them exactly the edit made next, against 31 % of all.
    static let sureEnough = -0.5

    private struct State {
        var process: Process?
        /// Where it answers, once its model is in.
        var base: URL?
        var starting: Task<SuggestAnswer, Never>?
        var idle: Task<Void, Never>?
        var pressure: DispatchSourceMemoryPressure?
        /// The system's memory is short (a warning, not yet back to normal): nothing starts unasked till it is.
        var pressed = false
        /// When a start last failed: an ask starts none again for `retryDelay`, as each pause in typing asks.
        var failedAt: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let command: String, idleDelay: Duration, startLimit: Duration, retryDelay: TimeInterval
    /// Where the running llama-server is noted ("<pid> <start time>", as `VMFolder.child`), so a kelpd that died
    /// without stopping it ends it at the next start; nil keeps no note.
    private let notes: URL?
    let http = URLSession(configuration: .ephemeral)

    /// `command` is llama-server's name on the login PATH, or a path; tests name a stand-in. `startLimit` is how long
    /// a start may take, the first one's 1.5 GB download included.
    init(
        command: String = "llama-server", idleDelay: Duration = .seconds(900), startLimit: Duration = .seconds(900),
        retryDelay: TimeInterval = 60, notes: URL? = nil
    ) {
        self.command = command
        self.idleDelay = idleDelay
        self.startLimit = startLimit
        self.retryDelay = retryDelay
        self.notes = notes
    }

    /// Starts llama-server unless it runs, and waits until its model is in (minutes, the first time).
    func start(_ offloads: Slots) async -> SuggestAnswer {
        let task = state.withLock { s in
            if let starting = s.starting, s.process?.isRunning != false { return starting }
            let made = Task { await self.launch(offloads) }
            s.starting = made
            return made
        }
        let answer = await task.value
        if answer.problem != nil {
            state.withLock { s in
                s.starting = nil   // the next start tries again
                s.failedAt = Date()
            }
        }
        return answer
    }

    /// Whether an ask may start llama-server: not while memory is short, nor soon after a start failed (a missing
    /// download or a crash would otherwise be tried again at every pause in typing). Start, the person's, always may.
    func mayStartUnasked() -> Bool {
        state.withLock { s in !s.pressed && s.failedAt.map { -$0.timeIntervalSinceNow >= retryDelay } != false }
    }

    /// The cursor's lines as the model would have them next; nothing while it starts (which this begins).
    func ask(_ request: EditorNextEdit, _ offloads: Slots) async throws -> SuggestAnswer {
        let base = state.withLock { s in s.process?.isRunning == true ? s.base : nil }
        guard let base else {
            if mayStartUnasked() { Task { _ = await start(offloads) } }
            return SuggestAnswer()
        }
        stayAwhile()
        let (data, response) = try await http.data(for: try Self.request(base, prompt: Self.prompt(request)))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return SuggestAnswer(problem: .failed) }
        return SuggestAnswer(text: try Self.answer(data))
    }

    /// Stops llama-server, waiting for it when `now` (the daemon is about to exit).
    func stop(now: Bool = false) {
        let process = state.withLock { s in
            defer {
                s.process = nil
                s.base = nil
                s.starting = nil
                s.idle = nil
            }
            s.idle?.cancel()
            s.starting?.cancel()
            return s.process
        }
        if let notes { FileManager.default.removeIfAny(VMFolder(notes).child(Self.note)) }
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        if now { Subprocess.stopTreeNow(pid) } else { Subprocess.stopTree(pid) }
    }

    /// The note's name in `notes`.
    static let note = "llama-server"

    private func launch(_ offloads: Slots) async -> SuggestAnswer {
        let (command, notes) = (command, notes)
        guard let port = Self.freePort(), let base = URL(string: "http://127.0.0.1:\(port)") else {
            return SuggestAnswer(problem: .failed)
        }
        let spawned: Process?
        do {
            spawned = try await offloads.run {
                if let notes, let pid = VMFolder(notes).endChild(Self.note) {
                    Log.rpc.notice("ended llama-server \(pid, privacy: .public), left by a kelpd that stopped")
                }
                return Self.spawn(command, port: port)
            }
        } catch {
            spawned = nil   // the daemon is stopping
        }
        guard let process = spawned else { return SuggestAnswer(problem: .noServer) }
        // Kept and checked under one lock, as `stop` cancels under it: a stop either comes first and is seen here, or
        // comes after and finds the process to end.
        let kept = state.withLock { s in
            guard !Task.isCancelled else { return false }
            s.process = process
            return true
        }
        guard kept else {   // switched off while it was being started
            Subprocess.stopTree(process.processIdentifier)
            return SuggestAnswer(problem: .failed)
        }
        note(process)
        watchMemory()
        let deadline = ContinuousClock.now + startLimit
        while process.isRunning, !Task.isCancelled {
            if await healthy(base) {
                let ready = state.withLock { s in
                    guard !Task.isCancelled else { return false }
                    s.base = base
                    return true
                }
                guard ready else { break }
                stayAwhile()
                return SuggestAnswer()
            }
            guard ContinuousClock.now < deadline else {
                Log.rpc.error("llama-server didn't get its model in within \(self.startLimit, privacy: .public)")
                stop()
                break
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        }
        return SuggestAnswer(problem: .failed)
    }

    /// Notes `process` in `notes`, to be ended by the next start if kelpd dies without stopping it.
    private func note(_ process: Process) {
        guard let notes else { return }
        let pid = process.processIdentifier
        do {
            try "\(pid) \(Subprocess.started(pid) ?? 0)".write(
                to: VMFolder(notes).child(Self.note), atomically: true, encoding: .utf8)
        } catch {
            Log.rpc.error("can't note llama-server's pid: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts `command` listening on `port`: off the cooperative pool, as a cold login-shell PATH takes seconds to
    /// find it. Nil when it isn't installed. What it last wrote to stderr goes to the log when it ends.
    private static func spawn(_ command: String, port: Int) -> Process? {
        guard let exe = LoginPath.find(command) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments + ["--port", "\(port)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginPath.value
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(), tail = OSAllocatedUnfairLock(initialState: Data())
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }   // it closed its end
            tail.withLock { $0 = ($0 + data).suffix(2048) }   // llama-server talks a lot: its last lines say why
        }
        process.terminationHandler = { ended in
            let said = tail.withLock { String(decoding: $0, as: UTF8.self) }
            let last = said.split(separator: "\n").suffix(3).joined(separator: " · ")
            let how = "\(ended.terminationReason == .exit ? "exit" : "signal") \(ended.terminationStatus)"
            Log.rpc.notice("llama-server ended (\(how, privacy: .public)): \(last, privacy: .public)")
        }
        do {
            try process.run()
        } catch {
            Log.rpc.error("llama-server didn't start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return process
    }

    private func healthy(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 1
        do {
            return (try await http.data(for: request).1 as? HTTPURLResponse)?.statusCode == 200   // 503 while loading
        } catch {
            return false   // not listening yet
        }
    }

    /// Stops it once it's gone unasked for `idleDelay`.
    private func stayAwhile() {
        let delay = idleDelay
        state.withLock { s in
            s.idle?.cancel()
            s.idle = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.stop()
            }
        }
    }

    /// A memory warning stops it, and no ask starts it again till memory is back to normal: agents and builds need the
    /// memory more.
    private func watchMemory() {
        state.withLock { s in
            guard s.pressure == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical], queue: .global())
            source.setEventHandler { [weak self, weak source] in
                guard let event = source?.data else { return }
                self?.memory(event)
            }
            source.resume()
            s.pressure = source
        }
    }

    /// The system's memory went to `event`'s level.
    func memory(_ event: DispatchSource.MemoryPressureEvent) {
        let short = !event.isDisjoint(with: [.warning, .critical])
        state.withLock { $0.pressed = short }
        if short { stop() }
    }

    /// A port nothing listens on now, from the system.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    /// Sweep Next-Edit's prompt, as it was trained: the edits made as diffs, then the cursor's lines before the latest
    /// and now, then where the model writes them as they'll be.
    static func prompt(_ r: EditorNextEdit) -> String {
        var parts: [String] = []
        for change in r.changes {
            parts += ["<|file_sep|>\(r.path).diff", "original:", change.old, "updated:", change.new]
        }
        parts += [
            "<|file_sep|>original/\(r.path)", r.original, "<|file_sep|>current/\(r.path)", r.current,
            "<|file_sep|>updated/\(r.path)", ""
        ]
        return parts.joined(separator: "\n")
    }

    static func request(_ base: URL, prompt: String) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("completion"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt, "n_predict": 512, "temperature": 0, "cache_prompt": true, "n_probs": 1,
            "stop": ["<|file_sep|>", "</s>"]
        ])
        return request
    }

    /// llama-server's `content`, unless a token of it was less sure than `sureEnough`.
    static func answer(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? String
        else { return nil }
        let probabilities = (json["completion_probabilities"] as? [[String: Any]] ?? []).compactMap {
            $0["logprob"] as? Double
        }
        return (probabilities.min() ?? 0) >= sureEnough ? content : nil
    }
}

extension EditorNextEdit: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> SuggestAnswer { try await lsp.nextEdit.ask(self, lsp.offloads) }
}

extension EditorNextEditStart: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> SuggestAnswer { await lsp.nextEdit.start(lsp.offloads) }
}

extension EditorNextEditStop: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> Done {
        lsp.nextEdit.stop()
        return Done()
    }
}
