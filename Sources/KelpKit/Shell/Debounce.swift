import Foundation

/// The last of a burst of calls runs, once they pause for `delay` seconds (file events, typing, layout saves).
@MainActor
package final class Debounce {
    package init() {}
    private var work: DispatchWorkItem?
    package func after(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated(action) }   // run on the main queue below
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    package func cancel() { work?.cancel() }
}
