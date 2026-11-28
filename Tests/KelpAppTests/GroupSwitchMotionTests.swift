import AppKit
import Core
import DesignKit
import TestSupport
import Testing
import WorkbenchKit

@testable import KelpApp
@testable import KelpKit

/// Switching the main window between groups: the new group is there at once, a picture of the old one leaves over it,
/// the new one settles, and the sidebar's pill glides to its row. Under Reduce Motion it just shows.

/// A tab that is only a view.
@MainActor private final class Plain: TabContent {
    let uri: String
    let view = NSView()
    var title: String { uri }
    var icon: NSImage? { nil }
    init(_ uri: String) { self.uri = uri }
    func focus() {}
    func close() async -> Bool { true }
}

/// A main window on screen (unseen, as every test's window is) over an app of its own: one project with two groups,
/// Alpha above Beta, Beta split in two panes, Alpha shown, the sidebar and inspector in their columns. Motion is as
/// `reduced` says until `done`. The window server keeps no picture of a see-through window, so a stand-in picture
/// is taken, and the places it was taken of are noted (`asked`).
@MainActor private final class Switching {
    let app: AppModel, main: MainWindowController
    var asked: [NSRect] = []
    init(reduced: Bool) {
        _ = testHome
        let pages = Builtin("test.switch", "Pages", "", icon: "doc") { _ in
            Contributions(tabs: [TabProvider(schemes: ["page"]) { Plain($0) }])
        }
        app = AppModel(builtins: Builtins.all + [pages])
        app.extensions.reload()
        main = MainWindowController(app: app)
        let path = "/tmp/kelp-switch-atlas"
        app.repos = [Repo(id: "r1", name: "Atlas", path: path)]
        app.worktrees = [("a", "Alpha"), ("b", "Beta")].map {
            Worktree(id: $0.0, repoId: "r1", branch: $0.0, path: path + "/" + $0.0, note: $0.1)
        }
        app.workbench.layouts["a"].add("page:a")
        var beta = app.workbench.layouts["b"]
        let left = beta.newGroup(beside: nil, vertical: true)
        beta.add("page:b1", to: left)
        beta.add("page:b2", to: beta.newGroup(beside: left, vertical: true))
        beta.manual = true   // split by hand, so it stays two panes
        app.workbench.layouts["b"] = beta
        let stand = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        NSView.takePicture = { [weak self] _, rect in
            self?.asked.append(rect)
            return stand
        }
        main.left.item.isCollapsed = false   // whatever this Mac's tests left in the split's autosave
        main.right.item.isCollapsed = false
        main.window?.orderFrontRegardless()   // only a window on screen moves
        Motion.pinned = reduced
        app.workbench.show(workspace: "a")
        main.window?.contentView?.layoutSubtreeIfNeeded()
    }
    func done() {
        Motion.pinned = nil
        NSView.takePicture = { $0.serverPicture(of: $1) }
        main.window?.orderOut(nil)   // not closed: a window made in code releases itself when it closes
    }
    var card: NSView? { main.editors.view.subviews.first { $0 is Card } }
    /// The editor areas the card holds.
    var areas: [String] {
        ["a", "b"].filter { id in card?.subviews.contains { $0 === main.editors.area(id)?.view } == true }
    }
    func pictures(over view: NSView?) -> [CALayer] {
        view?.layer?.sublayers?.filter { $0.name == NSView.leaving } ?? []
    }
    /// The springs `settleIn` gave Beta's strips and panes, by pane in reading order.
    func springs() -> [(strip: CASpringAnimation?, pane: CASpringAnimation?)] {
        let area = main.editors.area("b")
        return (area?.layout.root?.sessions ?? []).compactMap { area?.groupViews[$0] }.map {
            (
                $0.strip.layer?.animation(forKey: NSView.settling) as? CASpringAnimation,
                $0.container.layer?.animation(forKey: NSView.settling) as? CASpringAnimation
            )
        }
    }
    /// The sidebar's row of workspace `id`, once the sidebar shows it.
    func row(_ id: String) -> SidebarRowView? {
        let outline = main.sidebar.outline
        let row = (0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarController.Node)?.kind == .workspace(id)
        }
        return row.flatMap { outline.rowView(atRow: $0, makeIfNecessary: false) } as? SidebarRowView
    }
    var glides: [PillGlide] { main.sidebar.outline.subviews.compactMap { $0 as? PillGlide } }
}

extension OneAtATime {
    private static let shrinksAndBlurs: Set = ["opacity", "transform", "filters.blur.inputRadius"]

    /// The card holds the new group alone at once, under a picture of the old one, taken of the card, that shrinks,
    /// blurs and fades over `switchOut` once `switchHold` is over; the inspector's panel gets one that only fades. The
    /// new group's strips settle at once and its panes one after the other, on a spring that doesn't overshoot, from a
    /// little bigger.
    @Test func aSwitchLeavesAPictureOfTheOldGroupOverTheNewOne() async throws {
        let rig = Switching(reduced: false)
        defer { rig.done() }
        #expect(rig.areas == ["a"])
        let card = try #require(rig.card), panel = rig.main.inspector.panel
        #expect(try await waitFor(5) { !panel.isHiddenOrHasHiddenAncestor })   // the inspector follows Alpha
        let before = CACurrentMediaTime()
        rig.app.workbench.show(workspace: "b")
        let after = CACurrentMediaTime()
        /// Whether an animation starts `delay` after a moment within the switch.
        func starts(_ animation: CAAnimation?, after delay: TimeInterval) -> Bool {
            (before + delay...after + delay).contains(animation?.beginTime ?? 0)
        }
        // The card's picture hasn't started to leave by the time the switch is over (`switchHold`).
        let waiting = (rig.pictures(over: card).first?.animation(forKey: NSView.leaving)?.beginTime ?? 0) > after
        #expect(rig.areas == ["b"])
        #expect(rig.asked.contains(card.convert(card.bounds, to: nil)))
        #expect(rig.pictures(over: card).count == 1)
        let away = try #require(rig.pictures(over: card).first?.animation(forKey: NSView.leaving) as? CAAnimationGroup)
        #expect(away.duration == Motion.switchOut)
        #expect(Set(away.animations?.compactMap { ($0 as? CABasicAnimation)?.keyPath } ?? []) == Self.shrinksAndBlurs)
        // The inspector's panel only fades: shrunk, its rows ghosted over the new rows.
        #expect(rig.pictures(over: panel).count == 1)
        let fade = rig.pictures(over: panel).first?.animation(forKey: NSView.leaving) as? CAAnimationGroup
        #expect(fade?.duration == Motion.switchOut)
        #expect(fade?.animations?.compactMap { ($0 as? CABasicAnimation)?.keyPath } == ["opacity"])
        let springs = rig.springs()
        try #require(springs.count == 2)
        let start = try #require(springs[0].strip?.beginTime)
        // The card's picture stays whole for `switchHold` before it leaves, the inspector's leaves at once.
        #expect(waiting && starts(away, after: Motion.switchHold) && away.fillMode == .backwards)
        #expect(starts(fade, after: 0))
        for (index, spring) in springs.enumerated() {
            #expect(abs((spring.strip?.beginTime ?? 0) - start) < 0.005)
            #expect(abs((spring.pane?.beginTime ?? 0) - start - Double(index + 1) * Motion.switchStagger) < 0.005)
            #expect((spring.pane?.fromValue as? NSValue)?.caTransform3DValue.m11 == Motion.switchGrow)
            #expect(abs((spring.pane?.damping ?? 0) - 2 * sqrt(spring.pane?.stiffness ?? 0)) < 0.01)   // no overshoot
        }
        #expect(try await waitFor(5) { rig.pictures(over: card).isEmpty })
    }

    /// The sidebar's pill travels from the old group's row to the new one's, which draws its own once it's there. The
    /// group's name in the window bar rolls in, up: Beta is below Alpha. Both move on the spring the group settles on.
    @Test func aSwitchGlidesTheSidebarsPillToTheNewRow() async throws {
        let rig = Switching(reduced: false)
        defer { rig.done() }
        let outline = rig.main.sidebar.outline
        #expect(try await waitFor(5) { rig.row("a")?.isSelected == true && rig.row("b") != nil })
        let start = try #require(rig.row("a")), end = try #require(rig.row("b"))
        let from = start.convert(start.pillRect, to: outline), to = end.convert(end.pillRect, to: outline)
        #expect(rig.app.workbench.goesDown(from: "a", to: "b") == true)
        rig.app.workbench.show(workspace: "b")
        #expect(try await waitFor(5) { !rig.glides.isEmpty })
        let glide = try #require(rig.glides.first)
        #expect(glide.frame == to && end.pillWaits)
        let move = try #require(glide.layer?.animation(forKey: "glide") as? CABasicAnimation)
        let leaves = try #require((move.fromValue as? NSValue)?.pointValue)
        let lands = try #require((move.toValue as? NSValue)?.pointValue)
        #expect(abs(leaves.y - lands.y - (from.minY - to.minY)) < 0.5 && abs(leaves.x - lands.x) < 0.5)
        let settles = Motion.switchSpring("transform")
        /// Whether an animation moves on the switch's spring.
        func onTheSwitchSpring(_ animation: CAAnimation?) -> Bool {
            guard let spring = animation as? CASpringAnimation else { return false }
            return spring.duration == settles.duration && spring.stiffness == settles.stiffness
                && spring.damping == settles.damping
        }
        #expect(onTheSwitchSpring(move))
        let name = rig.main.bar.context.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        #expect(try await waitFor(5) { name?.stringValue == "Beta" })
        #expect(onTheSwitchSpring(name?.layer?.animation(forKey: "roll")))
        #expect(onTheSwitchSpring(name?.layer?.animation(forKey: "slide")))
        #expect(try await waitFor(5) { rig.glides.isEmpty && !end.pillWaits })
    }

    /// Under Reduce Motion a switch is the swap it always was: no picture, no spring, no glide.
    @Test func aSwitchUnderReduceMotionJustShows() async throws {
        let rig = Switching(reduced: true)
        defer { rig.done() }
        #expect(try await waitFor(5) { rig.row("a")?.isSelected == true })
        rig.app.workbench.show(workspace: "b")
        #expect(rig.areas == ["b"])
        #expect(rig.asked.isEmpty && rig.pictures(over: rig.card).isEmpty)
        #expect(rig.springs().allSatisfy { $0.strip == nil && $0.pane == nil })
        #expect(try await waitFor(5) { rig.row("b")?.isSelected == true })
        #expect(rig.glides.isEmpty)
    }
}
