import AppKit
import GhosttyKit

extension GhosttyTerminalView {
    /// The window going to the back (another app, another window) unfocuses the terminal typed in, as in Ghostty: an
    /// unfocused surface draws at most 30 times a second (scripts/ghostty-patches) and shows a hollow cursor.
    func followKey(of w: NSWindow) -> [NSObjectProtocol] {
        [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyChanged() }   // posted on main
            }
        }
    }

    private func keyChanged() {
        guard let surface, let w = window, w.firstResponder === self else { return }
        ghostty_surface_set_focus(surface, w.isKeyWindow)
    }
}
