import Core
import Foundation
import os

/// One ask of a kind at a time: a newer one cancels the one still running. The app drops an answer once typing goes
/// on, but the daemon would still wait for it, and a server that answers one ask at a time (Ollama, llama-server with
/// one slot) would write it before the newer one, so the gray text came later the faster one typed; a cloud provider
/// bills it. A cancelled ask's request is closed, which stops the server writing it, and it answers nothing.
final class LatestAsk: Sendable {
    private let running = OSAllocatedUnfairLock<Task<SuggestAnswer, any Error>?>(initialState: nil)

    func run(_ ask: @escaping @Sendable () async throws -> SuggestAnswer) async throws -> SuggestAnswer {
        let task = Task { try await ask() }
        running.withLock { previous in
            previous?.cancel()
            previous = task
        }
        let answer = await task.result
        guard !task.isCancelled else { return SuggestAnswer() }
        return try answer.get()
    }
}
