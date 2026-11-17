import AppKit
import Core
import DesignKit

/// How a CI run reads, in CI Runs (Issues) and on the Source Control panel (Git).
@MainActor
package enum CIRunLook {
    /// The mark for a run: ✓ green, ✕ red, the agents' spinning ring while it runs, an empty circle while it waits its
    /// turn, and a grey – when skipped or cancelled.
    package static func mark(_ status: String, _ conclusion: String?) -> NSView {
        let words = Self.words(status, conclusion)
        if status == "in_progress" {
            let ring = StatusMark(size: 12)   // as tall as the symbols beside it
            ring.status = .working
            ring.toolTip = words
            return ring
        }
        let (symbol, color): (String, NSColor) =
            switch (status, conclusion) {
            case ("completed", "success"?): ("checkmark.circle.fill", .systemGreen)
            case ("completed", "skipped"?), ("completed", "cancelled"?), ("completed", "neutral"?):
                ("minus.circle", .tertiaryLabelColor)
            case ("completed", _): ("xmark.circle.fill", .systemRed)
            default: ("circle", .tertiaryLabelColor)
            }
        let view = NSImageView(image: .symbol(symbol, words))
        view.contentTintColor = color
        view.toolTip = words
        view.symbolConfiguration = .chrome()
        return view
    }

    package static func words(_ status: String, _ conclusion: String?) -> String {
        switch (status, conclusion) {
        case ("completed", "success"?): String(localized: "Succeeded")
        case ("completed", "skipped"?): String(localized: "Skipped")
        case ("completed", "cancelled"?): String(localized: "Cancelled")
        case ("completed", "neutral"?): String(localized: "Neutral")
        case ("completed", _): String(localized: "Failed")
        case ("in_progress", _): String(localized: "Running")
        case ("waiting", _): String(localized: "Waiting for approval")
        default: String(localized: "Queued")
        }
    }

    package static func ago(_ iso: String) -> String {
        guard let date = CIRuns.date(iso) else { return "" }
        // "4m", "2h": one way to say when, as the graph and the sidebar do (it used to read "1d ago" here)
        return shortAgo(date)
    }
}

/// The CI built-in's mark (`FolderCI.mark`) where the shell shows one: a sidebar row, the branch chip. The mark is made
/// once there is a state to show, so a built-in switched on later still marks a row or chip made before.
@MainActor
final class CIMarkSlot {
    /// Where the mark sits, 12 pt wide. Clicks go through it to the chip or badge it's on.
    let view: NSView = PassThrough()
    private let app: AppModel
    private var mark: (view: NSView, show: @MainActor (CIRuns.State?, Bool) -> CGFloat)?
    var state: CIRuns.State? { didSet { if state != oldValue { refresh() } } }
    /// True under the pointer (on a sidebar row's CI badge). A failure then says "CI" where its dot was.
    var spelled = false { didSet { if spelled != oldValue { refresh() } } }
    /// How much wider than 12 pt the mark is now, which is the room a row must keep for it.
    private(set) var overhang: CGFloat = 0

    init(_ app: AppModel) {
        self.app = app
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 12), view.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    private func refresh() {
        if mark == nil, state != nil, let made = app.extensions.all.ci?.mark() {
            mark = made
            view.addSubview(made.view)
            NSLayoutConstraint.activate([
                made.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                made.view.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        overhang = mark?.show(state, spelled) ?? 0
    }

    /// An empty image that holds the mark's place in a button's title or image slot.
    static func room(_ side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in true }
    }

    private final class PassThrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
