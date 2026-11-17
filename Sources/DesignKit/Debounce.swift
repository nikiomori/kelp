import Foundation

/// Runs the last of a burst of calls, once they pause for `delay` seconds (file events, typing, layout saves).
@MainActor
public final class Debounce {
    public init() {}
    private var work: DispatchWorkItem?
    public func after(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated(action) }   // runs on the main queue below
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    public func cancel() { work?.cancel() }
}
