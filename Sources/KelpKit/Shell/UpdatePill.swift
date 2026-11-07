import AppKit
import Core
import DesignKit

/// The update that's ready, in the title bar between the traffic lights and the sidebar's toggle, which moves over for it
/// while the sidebar is away. Gone the rest of the time; a click relaunches into it.
@MainActor
final class UpdatePill: PointerButton {
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        radius = nil
        padding = 8
        restFill = .fillRest
        isHidden = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        onClick = { Task { await app.updates.install(app) } }
        track(owner: self) {
            app.themes.chromeText
        } changed: { [weak self] _ in
            self?.showWords()
        }
        track(owner: self) {
            app.updates.ready
        } changed: { [weak self] in
            self?.show($0)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Medium, in the accent: what has something to do, as the ↑3 on the branch chip.
    private func showWords() {
        attributedTitle = NSAttributedString(
            string: String(localized: "Update Kelp"),
            attributes: [.font: NSFont.ui(12, weight: .medium), .foregroundColor: NSColor.emphasis])
    }

    private func show(_ update: Updates.Ready?) {
        if isHidden != (update == nil) { crossfade(Motion.appear) }
        isHidden = update == nil
        guard let update else { return }
        toolTip = String(localized: "Kelp \(update.version) is ready. Click to restart.")
        menu = update.notes.map { url in
            let m = NSMenu()
            m.add(String(localized: "What's New")) { PreviewLinks.openOutside(url) }
            return m
        }
    }
}
