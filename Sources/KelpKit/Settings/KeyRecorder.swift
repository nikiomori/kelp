import AppKit

/// Takes the keys typed in Settings while a shortcut is recorded. It ends when a key comes for another window, which
/// gets that key, or when Settings stops being key: a click on a shortcut, then typing in a terminal or ⌘S in the
/// editor, used to be taken as the new shortcut.
@MainActor
final class KeyRecorder {
    private let window: NSWindow?
    private let key: (NSEvent) -> Void
    private let ended: () -> Void
    private var monitor: Any?
    private var resigned: NSObjectProtocol?

    /// Records in `window` (Settings): each key typed there goes to `key` and no further; `ended` is called when the
    /// recording ends by itself.
    init(in window: NSWindow?, key: @escaping (NSEvent) -> Void, ended: @escaping () -> Void) {
        self.window = window
        self.key = key
        self.ended = ended
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in self?.handle(ev) ?? ev }
        resigned = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }   // queue: .main
        }
    }

    /// What becomes of a key typed while recording: nil when Settings took it.
    func handle(_ ev: NSEvent) -> NSEvent? {
        guard let window, ev.windowNumber == window.windowNumber else {
            end()
            return ev
        }
        key(ev)
        return nil
    }

    /// Stops taking keys, without calling `ended`.
    func stop() {
        monitor.map(NSEvent.removeMonitor)
        resigned.map(NotificationCenter.default.removeObserver)
        monitor = nil
        resigned = nil
    }

    private func end() {
        stop()
        ended()
    }
}
