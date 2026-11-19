import Core
import Foundation

/// A model downloaded through Ollama's own API (`/api/pull`), into Ollama's own folder: Kelp asks, Ollama downloads.
extension LocalModels {

    func pull(_ model: String, conn: Int) async throws {
        pulling?.cancel()
        let download = Task { try await self.download(model, conn: conn) }
        pulling = download
        defer { if pulling == download { pulling = nil } }
        try await download.value
    }

    func cancelPull() { pulling?.cancel() }

    private func download(_ model: String, conn: Int) async throws {
        guard let base = ollama else { return }
        try await waitForOllama(base)
        var request = URLRequest(url: base.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60   // between bytes: the whole download may take many minutes
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (lines, _) = try await http.bytes(for: request)
        var told = Date.distantPast
        for try await line in lines.lines {
            let step = try Self.step(Data(line.utf8))
            if let error = step.error { throw RPCError.internalError(error) }
            if let total = step.total, Date().timeIntervalSince(told) > 0.2 {
                told = Date()
                clients?.notify(
                    SuggestPullEvent(model: model, completed: step.completed ?? 0, total: total), to: [conn])
            }
        }
        forget()   // the new model shows at the next look
    }

    /// One line of Ollama's answer: how far a layer has come, or what went wrong.
    static func step(_ data: Data) throws -> (completed: Int?, total: Int?, error: String?) {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (json["completed"] as? Int, json["total"] as? Int, json["error"] as? String)
    }

    /// Ollama just opened takes a few seconds to listen: ask twice a second, for 30 s at most.
    private func waitForOllama(_ base: URL) async throws {
        var request = URLRequest(url: base.appendingPathComponent("api/version"))
        request.timeoutInterval = 0.5
        for _ in 0..<waits {
            do {
                _ = try await http.data(for: request)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw RPCError.internalError(String(localized: "Ollama isn't running."))
    }
}

extension EditorSuggestPull: AsyncHandled {
    func handle(_ lsp: LSPHost, conn: Int) async throws -> Done {
        try await lsp.models.pull(model, conn: conn)
        return Done()
    }
}

extension EditorSuggestPullCancel: AsyncHandled {
    func handle(_ lsp: LSPHost) async throws -> Done {
        await lsp.models.cancelPull()
        return Done()
    }
}
