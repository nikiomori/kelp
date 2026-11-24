import AppKit
import Core
import DesignKit

/// How a CI run reads, in CI Runs (Issues) and on the Source Control panel (Git).
@MainActor
package enum CIRunLook {
    /// The mark for a run: a grey filled ✓, as the sidebar's CI mark draws a pass, ✕ red, the agents' spinning ring
    /// while it runs, their orange waiting ring while it waits for someone's approval (as the sidebar's CI mark), an
    /// empty circle while it waits its turn, and a grey – when skipped or cancelled, all in secondary grey, because the
    /// mark is the only copy of the state on the row and the shapes tell them apart. A pass is not green: colour is
    /// kept for what broke or waits for you.
    package static func mark(_ status: String, _ conclusion: String?) -> NSView {
        let words = Self.words(status, conclusion)
        let ringStatus: AgentStatus? =
            status == "in_progress" ? .working : approval(status, conclusion) ? .waiting : nil
        if let ringStatus {
            let ring = StatusMark(size: 12)   // as tall as the symbols beside it
            ring.status = ringStatus
            ring.toolTip = words
            return ring
        }
        let (symbol, color): (String, NSColor) =
            switch (status, conclusion) {
            case ("completed", "success"?): ("checkmark.circle.fill", .secondaryLabelColor)
            case ("completed", "skipped"?), ("completed", "cancelled"?), ("completed", "neutral"?):
                ("minus.circle", .secondaryLabelColor)
            case ("completed", _): ("xmark.circle.fill", .systemRed)
            default: ("circle", .secondaryLabelColor)
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
        case _ where approval(status, conclusion): String(localized: "Waiting for approval")
        case ("completed", _): String(localized: "Failed")
        case ("in_progress", _): String(localized: "Running")
        default: String(localized: "Queued")
        }
    }

    /// True when a run waits for someone's approval (a deploy to a protected environment, a fork's first run), which
    /// the sidebar's CI mark counts as waiting (`CIRuns.state`).
    private static func approval(_ status: String, _ conclusion: String?) -> Bool {
        status == "waiting" || conclusion == "action_required"
    }

    /// The tooltip's line for a run's row that a ⌘-click opens on its site: GitLab's pipelines are under "/-/".
    package static func clickTip(_ url: String) -> String {
        String(localized: "⌘-click: open on \(url.contains("/-/pipelines/") ? "GitLab" : "GitHub")")
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
