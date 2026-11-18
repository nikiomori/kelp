import AppKit
import Core
import DesignKit
import KelpKit

/// The buttons beside the branch, as in every panel header: two quiet actions and ⋯ (DS PanelHeader). They are Pull
/// and Push, with how many commits each moves; Push is in the accent colour while there's something to push, and
/// says Publish for a branch with no upstream. Commit is the panel's own button, and Fetch, Stash and Refresh are in
/// ⋯, because seven icons there (two down arrows among them, with "56" between) read as a toolbar, not a header. The
/// keys in the tooltips are the Git commands' keys.
@MainActor
final class SourceControlBar {
    let pull: NSButton, push: NSButton, more: NSButton
    var buttons: [NSButton] { [pull, push, more] }
    private let keys: ExtensionRegistry

    init(_ owner: SourceControlController) {
        let keys = owner.app.extensions
        self.keys = keys
        func b(_ symbol: String, _ tip: String, _ action: @escaping (SourceControlController) -> Void) -> NSButton {
            IconButton(.symbol(symbol), tip: tip) { [weak owner] in if let owner { action(owner) } }
        }
        pull = b("arrow.down", keys.hint(String(localized: "Pull"), "git.pull")) { $0.pullPressed() }
        push = b("arrow.up", keys.hint(String(localized: "Push"), "git.push")) { $0.pushPressed() }
        more = b("ellipsis.circle", String(localized: "More Actions")) { $0.showMoreMenu() }
    }

    /// A count changes with a fade, so it reads as the number moving on, not as a jump.
    private func show(_ count: String, _ any: Bool, on button: NSButton) {
        let words = any ? count : ""
        guard button.title != words else { return }
        if button.window != nil { button.crossfade() }
        button.title = words
    }

    /// Shows commits on their way: the shade runs up Push's arrow or down Pull's arrow.
    func flow(push moving: Bool, pull coming: Bool) {
        push.flow(up: moving ? true : nil)
        pull.flow(up: coming ? false : nil)
    }

    /// The header: the branch, then the buttons.
    func header(_ branch: NSView) -> Bar { Bar.panel([branch], buttons) }

    func update(_ info: BranchInfo?, changes: Int, busy: Bool) {
        let up = info?.upstream, ahead = info?.ahead ?? 0, behind = info?.behind ?? 0
        let publish = up == nil && info?.current != nil && !(info?.remote.isEmpty ?? true)
        pull.isEnabled = !busy && up != nil
        show("\(behind)", behind > 0, on: pull)
        pull.contentTintColor = behind > 0 ? .labelColor : .secondaryLabelColor
        pull.toolTip =
            up.map {
                keys.hint(
                    behind > 0 ? String(localized: "Pull \(behind) from \($0)") : String(localized: "Pull from \($0)"),
                    "git.pull")
            }
            ?? String(localized: "Pull (no upstream)")
        push.isEnabled = !busy && (publish || (up != nil && ahead > 0))
        push.image = .symbol(publish ? "arrow.up.to.line" : "arrow.up", String(localized: "Push"))
        show("\(ahead)", ahead > 0, on: push)
        push.contentTintColor = ahead > 0 || publish ? .emphasis : .secondaryLabelColor
        let pushTip = up.map {
            ahead > 0
                ? keys.hint(String(localized: "Push \(ahead) to \($0)"), "git.push")
                : String(localized: "Nothing to push to \($0)")
        }
        push.toolTip =
            publish
            ? keys.hint(String(localized: "Publish Branch"), "git.push")
            : pushTip ?? keys.hint(String(localized: "Push"), "git.push")
    }
}
