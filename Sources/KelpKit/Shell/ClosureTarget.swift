import AppKit

package final class ClosureButton: NSButton {
    private var handler: (() -> Void)?
    package convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { handler?() }
}

/// A menu item's or control's action as a closure; AppKit sends actions on the main thread.
@MainActor
package final class ClosureTarget: NSObject {
    let handler: @MainActor () -> Void
    package init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc package func fire() { handler() }
}
