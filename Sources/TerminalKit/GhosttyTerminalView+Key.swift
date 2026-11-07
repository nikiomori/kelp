import AppKit
import GhosttyKit

extension GhosttyTerminalView {
    /// The window going to the back (another app, another window) unfocuses the terminal typed in, as in Ghostty: an
    /// unfocused surface draws output at most 30 times a second, a scroll at once (scripts/ghostty-patches), and shows a
    /// hollow cursor.
    func followKey(of window: NSWindow) -> [NSObjectProtocol] {
        [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyChanged() }   // posted on main
            }
        }
    }

    private func keyChanged() {
        guard let surface, let window, window.firstResponder === self else { return }
        ghostty_surface_set_focus(surface, window.isKeyWindow)
    }
}
