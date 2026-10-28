import AppKit
import Core
import DesignKit
import KelpKit

/// Beside the branch, as every panel header: two quiet actions and ⋯ (DS PanelHeader). Pull and Push, with how many
/// commits each moves (Push in the accent colour while there's something to push, Publish for a branch with no
/// upstream); Commit is the panel's own button, and Fetch, Stash and Refresh are in ⋯. Seven icons there (two down
/// arrows among them, "56" between them) read as a toolbar, not a header. The keys in the tooltips are the Git commands'.
@MainActor
final class SourceControlBar {
    let pull: NSButton, push: NSButton, more: NSButton
    var buttons: [NSButton] { [pull, push, more] }

    init(_ owner: SourceControlController) {
        func b(_ symbol: String, _ tip: String, _ action: @escaping (SourceControlController) -> Void) -> NSButton {
            IconButton(.symbol(symbol), tip: tip) { [weak owner] in if let owner { action(owner) } }
        }
        pull = b("arrow.down", String(localized: "Pull (⌥⌘X)")) { $0.pullPressed() }
        push = b("arrow.up", String(localized: "Push (⌥⌘P)")) { $0.pushPressed() }
        more = b("ellipsis.circle", String(localized: "More Actions")) { $0.showMoreMenu() }
    }

    /// The header: the branch, then the buttons.
    func header(_ branch: NSView) -> Bar { Bar.panel([branch], buttons) }

    func update(_ info: BranchInfo?, changes: Int, busy: Bool) {
        let up = info?.upstream, ahead = info?.ahead ?? 0, behind = info?.behind ?? 0
        let publish = up == nil && info?.current != nil && !(info?.remote.isEmpty ?? true)
        pull.isEnabled = !busy && up != nil
        pull.title = behind > 0 ? "\(behind)" : ""
        pull.contentTintColor = behind > 0 ? .labelColor : .secondaryLabelColor
        pull.toolTip = up.map { behind > 0 ? String(localized: "Pull \(behind) from \($0) (⌥⌘X)") : String(localized: "Pull from \($0) (⌥⌘X)") }
            ?? String(localized: "Pull (no upstream)")
        push.isEnabled = !busy && (publish || (up != nil && ahead > 0))
        push.image = .symbol(publish ? "arrow.up.to.line" : "arrow.up", String(localized: "Push"))
        push.title = ahead > 0 ? "\(ahead)" : ""
        push.contentTintColor = ahead > 0 || publish ? .emphasis : .secondaryLabelColor
        let pushTip = up.map { ahead > 0 ? String(localized: "Push \(ahead) to \($0) (⌥⌘P)") : String(localized: "Nothing to push to \($0)") }
        push.toolTip = publish ? String(localized: "Publish Branch (⌥⌘P)") : pushTip ?? String(localized: "Push (⌥⌘P)")
    }
}
