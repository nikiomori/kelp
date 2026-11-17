import AppKit
import DesignKit

/// The window's first frame: drawn with settings.json's theme and fonts, and only then the work that can wait.
extension AppDelegate {
    /// How long the window waits for settings.json, so its first frame has their theme and fonts, not the defaults'.
    static let settingsWait: TimeInterval = 0.15

    /// Shown the turn after the settings are in (the theme looks at them first), or after `settingsWait`; libghostty starts
    /// after that frame, with the terminals' look from them, and Sparkle after the first.
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
            Self.afterFirstPaint { self?.updater?.startUpdater() }   // once, as Sparkle wants
        }
    }

    private func showMain() { if main.window?.isVisible != true { main.showWindow(nil) } }

    /// Once Core Animation has committed what's on screen now (its own observer runs before this one), on the next turn.
    static func afterFirstPaint(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max) {
            _, _ in DispatchQueue.main.async { MainActor.assumeIsolated(work) }   // the main run loop's observer
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
