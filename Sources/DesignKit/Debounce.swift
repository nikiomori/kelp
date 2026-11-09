import Foundation

/// The last of a burst of calls runs, once they pause for `delay` seconds (file events, typing, layout saves).
@MainActor
public final class Debounce {
    public init() {}
    private var work: DispatchWorkItem?
    public func after(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated(action) }   // run on the main queue below
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    public func cancel() { work?.cancel() }
}
