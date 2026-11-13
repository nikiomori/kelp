import AppKit

public final class ClosureButton: NSButton {
    private var handler: ClosureTarget?   // target is weak: the button keeps it
    public convenience init(title: String, action: @escaping @MainActor () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = ClosureTarget(action)
        target = handler
        self.action = #selector(ClosureTarget.fire)
    }
}

/// A menu item's or control's action as a closure; AppKit sends actions on the main thread.
@MainActor
public final class ClosureTarget: NSObject {
    let handler: @MainActor () -> Void
    public init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc public func fire() { handler() }
}
