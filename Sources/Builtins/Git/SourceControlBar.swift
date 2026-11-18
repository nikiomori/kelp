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
        func b(_ symbol: String?, _ tip: String, _ action: @escaping (SourceControlController) -> Void) -> NSButton {
            IconButton(symbol.map { .symbol($0) }, tip: tip) { [weak owner] in if let owner { action(owner) } }
        }
        pull = b(nil, keys.hint(String(localized: "Pull"), "git.pull")) { $0.pullPressed() }
        push = b(nil, keys.hint(String(localized: "Push"), "git.push")) { $0.pushPressed() }
        more = b("ellipsis.circle", String(localized: "More Actions")) { $0.showMoreMenu() }
    }

    /// Writes what a button moves as the title bar's chip writes it (`NSAttributedString.signed`): the arrow, and the
    /// count while there is one, so ↑37 is one drawing in both. The chrome's 13 pt arrow with a small count beside
    /// it was a second one. A count changes with a fade, so it reads as the number moving on, not as a jump.
    private func show(_ arrow: String, _ count: Int, _ color: NSColor, on button: NSButton) {
        let mark = "\(arrow) \(count) \(color == .secondaryLabelColor)"
        guard shown[ObjectIdentifier(button)] != mark else { return }
        shown[ObjectIdentifier(button)] = mark
        if button.window != nil { button.crossfade() }
        button.attributedTitle = .signed(arrow, count > 0 ? count : nil, size: TextSize.row, color: color)
        button.imagePosition = .noImage
    }
    private var shown: [ObjectIdentifier: String] = [:]

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
        show("arrow.down", behind, behind > 0 ? .labelColor : .secondaryLabelColor, on: pull)
        pull.toolTip =
            up.map {
                keys.hint(
                    behind > 0 ? String(localized: "Pull \(behind) from \($0)") : String(localized: "Pull from \($0)"),
                    "git.pull")
            }
            ?? String(localized: "Pull (no upstream)")
        push.isEnabled = !busy && (publish || (up != nil && ahead > 0))
        show(
            publish ? "arrow.up.to.line" : "arrow.up", ahead, ahead > 0 || publish ? .emphasis : .secondaryLabelColor,
            on: push)
        let pushTip = up.map {
            ahead > 0
                ? keys.hint(String(localized: "Push \(ahead) to \($0)"), "git.push")
                : String(localized: "Nothing to push to \($0)")
        }
        push.toolTip =
            publish
            ? keys.hint(String(localized: "Publish Branch"), "git.push")
            : pushTip ?? keys.hint(String(localized: "Push"), "git.push")
        // VoiceOver hears the tooltip's words ("Push 37 to origin/main"): the title is a picture and a number.
        for button in [pull, push] { button.setAccessibilityLabel(button.toolTip) }
    }
}
