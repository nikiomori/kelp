import AppKit
import Sparkle

/// An update Sparkle downloaded by itself and has ready to go. Nothing interrupts: `UpdatePill` and the Kelp menu offer it,
/// a click installs it and relaunches, and an ordinary quit installs it too.
@MainActor
@Observable
final class Updates: NSObject {
    struct Ready: Equatable { var version: String, notes: URL? }

    private(set) var ready: Ready?
    /// Sparkle's, made by the app delegate; nil in a build without a feed (a debug one, Kelp Dev).
    @ObservationIgnored weak var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    private static let versionKey = "update.version", notesKey = "update.notes"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Kept for the next launch, which may be this update's: however it got installed, that launch says so.
    func arrived(_ update: Ready, install: @escaping () -> Void) {
        ready = update
        installNow = install
        defaults.set(update.version, forKey: Self.versionKey)
        defaults.set(update.notes?.absoluteString, forKey: Self.notesKey)
    }

    /// The update this launch is, once. A newer download than the one that got installed waits for its own launch.
    func installed(current: String) -> Ready? {
        guard defaults.string(forKey: Self.versionKey) == current else { return nil }
        defer { defaults.removeObject(forKey: Self.versionKey); defaults.removeObject(forKey: Self.notesKey) }
        return Ready(version: current, notes: defaults.string(forKey: Self.notesKey).flatMap(URL.init(string:)))
    }

    func sayInstalled() {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let update = installed(current: current) else { return }
        Banner.show(String(localized: "Kelp updated to \(current)"), action: update.notes.map { url in
            (String(localized: "What's New"), { @MainActor in PreviewLinks.openOutside(url) })
        })
    }

    /// Relaunches into the update; unsaved files ask first, as for any quit. Without leave to run in the background macOS
    /// ends the agents with the app, so that takes a yes.
    func install(_ app: AppModel) async {
        if app.sessions.contains(where: { $0.status != .exited }), await BackgroundItem.blocked, await !agentsMayEnd() { return }
        installNow?()
    }

    private func agentsMayEnd() async -> Bool {
        let a = NSAlert()
        a.messageText = String(localized: "Updating ends running agents")
        a.informativeText = String(localized: "Kelp isn't allowed to run in the background, so macOS ends its agents when it quits.")
        a.addButton(withTitle: String(localized: "Later"))   // Return keeps the agents running
        a.addButton(withTitle: String(localized: "Open Login Items"))
        a.addButton(withTitle: String(localized: "Update Anyway")).hasDestructiveAction = true
        switch await runSheet(a) {
        case .alertSecondButtonReturn: BackgroundItem.openSettings(); return false
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}

extension Updates: SPUUpdaterDelegate {
    /// Downloaded and unpacked. Answering true holds the update here until the block runs, and Sparkle looks for no newer
    /// one meanwhile; the block may run again after a quit that unsaved files cancelled.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        let update = Ready(version: item.displayVersionString, notes: item.fullReleaseNotesURL)
        nonisolated(unsafe) let install = install
        MainActor.assumeIsolated { arrived(update) { install() } }   // Sparkle calls its delegate on the main thread
        return true
    }
}
