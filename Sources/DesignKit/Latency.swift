import Foundation

/// The latency rule: a quick answer changes nothing on screen. What says "wait" (a line, a spinner, the stage) appears
/// only once the wait is long enough to notice (a second). Cancel the task when the answer comes. The exception is a
/// place with nothing to show yet that asks a server: it won't answer within that second, so its wait shows at once
/// (and stays `LoadingView.held`).
@MainActor @discardableResult
public func whileSlow(_ show: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        do { try await Task.sleep(for: .seconds(1)) } catch { return }   // cancelled, because the answer came
        show()
    }
}
