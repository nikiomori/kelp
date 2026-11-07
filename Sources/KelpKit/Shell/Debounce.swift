import Foundation

/// The last of a burst of calls runs, once they pause for `delay` seconds (file events, typing, layout saves).
@MainActor
package final class Debounce {
    package init() {}
    private var work: DispatchWorkItem?
    package func after(_ delay: Double, _ f: @escaping @MainActor () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated(f) }   // run on the main queue below
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    package func cancel() { work?.cancel() }
}
