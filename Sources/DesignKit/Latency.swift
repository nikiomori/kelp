import Foundation

/// The latency rule: a quick answer changes nothing on screen; "Loading…", a spinner or the stage appear only once
/// the wait is long enough to notice (a second). Cancel the task when the answer comes.
@MainActor @discardableResult
public func whileSlow(_ show: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        do { try await Task.sleep(for: .seconds(1)) } catch { return }   // cancelled: the answer came
        show()
    }
}
