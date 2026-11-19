import Core
import Foundation
import os

/// The model that guesses the next edit, Sweep Next-Edit 1.5B (Apache-2.0), in a llama-server (llama.cpp) that kelpd
/// starts on a free port of its own: for the first ask, or Start. It stops after 15 minutes unasked, on a memory
/// warning, when the next edit is switched off, and with the daemon. The first start downloads the model (1.5 GB)
/// into llama.cpp's cache. Prompt lookup (ngram-simple) does it: the model writes the cursor's lines again, most of
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
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let command: String, idleDelay: Duration
    let http = URLSession(configuration: .ephemeral)

    /// `command` is llama-server's name on the login PATH; tests name one that isn't there.
    init(command: String = "llama-server", idleDelay: Duration = .seconds(900)) {
        self.command = command
        self.idleDelay = idleDelay
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
        if answer.problem != nil { state.withLock { $0.starting = nil } }   // the next ask tries again
        return answer
    }

    /// The cursor's lines as the model would have them next; nothing while it starts (which this begins).
    func ask(_ request: EditorNextEdit, _ offloads: Slots) async throws -> SuggestAnswer {
        let base = state.withLock { s in s.process?.isRunning == true ? s.base : nil }
        guard let base else {
            Task { _ = await start(offloads) }
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
            defer { s = State(pressure: s.pressure) }
            s.idle?.cancel()
            s.starting?.cancel()
            return s.process
        }
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        if now { Subprocess.stopTreeNow(pid) } else { Subprocess.stopTree(pid) }
    }

    private func launch(_ offloads: Slots) async -> SuggestAnswer {
        let command = command
        guard let port = Self.freePort(), let base = URL(string: "http://127.0.0.1:\(port)") else {
            return SuggestAnswer(problem: .failed)
        }
        let spawned: Process?
        do {
            spawned = try await offloads.run { Self.spawn(command, port: port) }
        } catch {
            spawned = nil   // the daemon is stopping
        }
        guard let process = spawned else { return SuggestAnswer(problem: .noServer) }
        guard !Task.isCancelled else {   // switched off while it was being started
            Subprocess.stopTree(process.processIdentifier)
            return SuggestAnswer(problem: .failed)
        }
        state.withLock { $0.process = process }
        watchMemory()
        while process.isRunning, !Task.isCancelled {
            if await healthy(base) {
                state.withLock { $0.base = base }
                stayAwhile()
                return SuggestAnswer()
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        }
        return SuggestAnswer(problem: .failed)
    }

    /// Starts `command` listening on `port`: off the cooperative pool, as a cold login-shell PATH takes seconds to
    /// find it. Nil when it isn't installed.
    private static func spawn(_ command: String, port: Int) -> Process? {
        guard let exe = LoginPath.find(command) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments + ["--port", "\(port)"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginPath.value
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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

    /// A memory warning stops it: agents and builds need the memory more.
    private func watchMemory() {
        state.withLock { s in
            guard s.pressure == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            s.pressure = source
        }
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
