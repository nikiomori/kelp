import AppKit
import Core
import DesignKit
import KelpKit

/// The quick actions beside the branch: Commit, Pull and Push (with how many commits each moves; Push in the accent
/// colour while there's something to push, Publish for a branch with no upstream), Fetch, Stash, Refresh, and ⋯.
/// The keys in the tooltips are the Git commands' (`GitBuiltin`). On a narrow panel Stash and Fetch give way first;
/// ⋯ has them too.
@MainActor
final class SourceControlBar {
    let commit: NSButton, pull: NSButton, push: NSButton, fetch: NSButton, stash: NSButton, refresh: NSButton, more: NSButton
    var buttons: [NSButton] { [commit, pull, push, fetch, stash, refresh, more] }

    init(_ owner: SourceControlController) {
        func b(_ symbol: String, _ tip: String, _ action: @escaping (SourceControlController) -> Void) -> NSButton {
            IconButton(.symbol(symbol), tip: tip) { [weak owner] in if let owner { action(owner) } }
        }
        commit = b("checkmark", String(localized: "Commit (⌥⌘C)")) { $0.commitPressed() }
        pull = b("arrow.down", String(localized: "Pull (⌥⌘X)")) { $0.pullPressed() }
        push = b("arrow.up", String(localized: "Push (⌥⌘P)")) { $0.pushPressed() }
        fetch = b("arrow.down.circle", String(localized: "Fetch (⌥⌘F)")) { $0.fetchPressed() }
        stash = b("tray.and.arrow.down", String(localized: "Stash Changes")) { $0.run(done: String(localized: "Changes stashed")) { GitStash(id: $0) } }
        refresh = b("arrow.clockwise", String(localized: "Refresh")) { $0.reloadAll() }
        more = b("ellipsis.circle", String(localized: "More Actions")) { $0.showMoreMenu() }
    }

    /// The header: the branch, then the buttons, the ones that give way first last in line for the room.
    func header(_ branch: NSView) -> Bar {
        let bar = Bar.panel([branch], buttons)
        bar.stack.setVisibilityPriority(.init(300), for: stash)
        bar.stack.setVisibilityPriority(.init(400), for: fetch)
        return bar
    }

    func update(_ info: BranchInfo?, changes: Int, busy: Bool) {
        let up = info?.upstream, ahead = info?.ahead ?? 0, behind = info?.behind ?? 0
        let publish = up == nil && info?.current != nil && !(info?.remote.isEmpty ?? true)
        commit.isEnabled = !busy && changes > 0
        stash.isEnabled = !busy && changes > 0
        pull.isEnabled = !busy && up != nil
        pull.title = behind > 0 ? "\(behind)" : ""
        pull.contentTintColor = behind > 0 ? .labelColor : .secondaryLabelColor
        pull.toolTip = up.map { behind > 0 ? String(localized: "Pull \(behind) from \($0) (⌥⌘X)") : String(localized: "Pull from \($0) (⌥⌘X)") }
            ?? String(localized: "Pull (no upstream)")
        push.isEnabled = !busy && (publish || (up != nil && ahead > 0))
        push.image = .symbol(publish ? "arrow.up.circle" : "arrow.up", String(localized: "Push"))
        push.title = ahead > 0 ? "\(ahead)" : ""
        push.contentTintColor = ahead > 0 || publish ? .controlAccentColor : .secondaryLabelColor
        let pushTip = up.map { ahead > 0 ? String(localized: "Push \(ahead) to \($0) (⌥⌘P)") : String(localized: "Nothing to push to \($0)") }
        push.toolTip = publish ? String(localized: "Publish Branch (⌥⌘P)") : pushTip ?? String(localized: "Push (⌥⌘P)")
        fetch.isEnabled = !busy && !(info?.remote.isEmpty ?? true)
    }
}
