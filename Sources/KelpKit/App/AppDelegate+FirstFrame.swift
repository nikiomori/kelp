import AppKit
import DesignKit

/// Draws the window's first frame with settings.json's theme and fonts, and only then does the work that can wait.
extension AppDelegate {
    /// How long the window waits for settings.json, so its first frame has the user's theme and fonts, not the
    /// defaults.
    static let settingsWait: TimeInterval = 0.15

    /// Shows the window on the turn after the settings are in (the theme looks at them first), or after
    /// `settingsWait`. libghostty starts after that frame, with the terminals' look taken from the settings, and
    /// Sparkle starts after the first frame.
    func showWhenSettingsArrive() {
        track(owner: self) { [app] in
            app.settings.loaded
        } changed: { [weak self] loaded in
            guard loaded else { return }
            DispatchQueue.main.async {
                self?.showMain()
                Self.afterFirstPaint(ThemeManager.warmTerminals)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settingsWait) { [weak self] in
            self?.showMain()
            Self.afterFirstPaint { self?.updater?.startUpdater() }   // only once, as Sparkle wants
        }
    }

    private func showMain() { if main.window?.isVisible != true { main.showWindow(nil) } }

    /// Runs `work` on the next turn, once Core Animation has committed what's on screen now (Core Animation's own
    /// observer runs before this one).
    static func afterFirstPaint(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max) {
            _, _ in DispatchQueue.main.async { MainActor.assumeIsolated(work) }   // it observes the main run loop
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
