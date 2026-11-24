import AppKit
import DesignKit

/// One editor group: its tab strip over the selected tab's content. Dropping a tab on an edge splits the group.
@MainActor
final class GroupView: NSView {
    let groupId: String
    let strip = TabStrip()
    private let container = NSView()
    private let hint = DropHint()
    private weak var shown: NSView?
    private let veil = Veil()
    private let ring = EdgeGlow(radius: Metrics.radiusSM, spread: 14)
    /// A glow inside the content's edges when the tab's agent calls for you (it clears once you've looked or answered).
    var attention: NSColor? {
        didSet { if attention != oldValue { ring.show(attention, breathing: breathing) } }
    }
    /// The glow breathes while the agent waits for an answer (it stays still with Reduce Motion).
    var breathing = false {
        didSet { if breathing != oldValue { ring.show(attention, breathing: breathing) } }
    }
    var onDropTab: ((String, NSRectEdge?) -> Void)?   // nil edge = into this group
    /// Files from Finder or the Files panel, dropped on a tab that isn't a terminal (a terminal types their paths).
    var onDropFiles: (([URL]) -> Void)?
    /// Handles a tab dropped right at an outer side of the whole editor area, which splits along all of it.
    var onDropOuter: ((String, NSRectEdge) -> Void)?
    /// The editor area's frame in window coordinates (nil when there is none), and a hint drawn across it.
    var editorFrame: (() -> NSRect?)?
    var showOuterHint: ((NSRectEdge?) -> Void)?
    /// Whether this is a pane without focus, among several. Such a pane fades toward the terminal's background (Ghostty
    /// does the same).
    var dimmed = false {
        didSet {
            guard dimmed != oldValue else { return }
            veil.layer?.backgroundColor = themes.terminalBackground.withAlphaComponent(Metrics.paneDim).cgColor
            if dimmed {
                veil.alphaValue = 0
                veil.isHidden = false
            }
            NSAnimationContext.runAnimationGroup(
                { ctx in
                    ctx.duration = Motion.duration(Motion.fast)
                    veil.animator().alphaValue = dimmed ? 1 : 0
                },
                completionHandler: { [weak self] in
                    MainActor.assumeIsolated {   // AppKit runs the completion on the main thread
                        if let self, !self.dimmed { self.veil.isHidden = true }
                    }
                })
        }
    }

    private let themes: ThemeManager

    init(groupId: String, themes: ThemeManager) {
        self.groupId = groupId
        self.themes = themes
        super.init(frame: .zero)
        veil.wantsLayer = true
        veil.isHidden = true
        for subview in [strip, container, veil, ring] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        addSubview(hint)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor), strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            veil.topAnchor.constraint(equalTo: container.topAnchor),
            veil.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ring.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            ring.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            ring.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            ring.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -1)
        ])
        registerForDraggedTypes([.kelpTab, .fileURL])
        track(owner: self) {
            themes.look.card
        } changed: { [strip] in
            strip.fill = $0
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ content: NSView?) {
        guard content !== shown || content?.superview !== container else { return }
        // Remove the old view only if it's still here, because a tab moved to another group took its view along.
        if shown?.superview === container {
            if content != nil { container.crossfade() }   // one tab's content fades into the next
            shown?.removeFromSuperview()
        }
        shown = content
        guard let content else { return }
        content.removeFromSuperview()
        container.pin(content)
    }

    // MARK: tab dropped on the content: an edge splits, the middle moves the tab here

    /// Returns the side of this group that is also a side of the editor area, when the drop is within 18 pt of it.
    private func outerEdge(_ sender: NSDraggingInfo) -> NSRectEdge? {
        guard let area = editorFrame?() else { return nil }
        let me = convert(bounds, to: nil), point = sender.draggingLocation, near: CGFloat = 18
        if abs(me.minX - area.minX) < 1, point.x - me.minX < near { return .minX }
        if abs(me.maxX - area.maxX) < 1, me.maxX - point.x < near { return .maxX }
        if abs(me.maxY - area.maxY) < 1, me.maxY - point.y < near, point.y < me.maxY - strip.frame.height {
            return .maxY
        }
        if abs(me.minY - area.minY) < 1, point.y - me.minY < near { return .minY }
        return nil
    }
    private func edge(_ sender: NSDraggingInfo) -> NSRectEdge? {
        let point = container.convert(sender.draggingLocation, from: nil), inner = container.bounds
        guard inner.width > 0, inner.height > 0 else { return nil }
        let fx = point.x / inner.width, fy = point.y / inner.height
        let nearest = min(fx, 1 - fx, fy, 1 - fy)
        guard nearest < 0.25 else { return nil }
        if nearest == fx { return .minX }
        if nearest == 1 - fx { return .maxX }
        return nearest == fy ? .minY : .maxY
    }
    private func showHint(_ edge: NSRectEdge?) {
        var hintFrame = DropHint.across(container.frame)
        if let edge { hintFrame = hintFrame.share(1 / 2, from: edge) }
        hint.show(hintFrame)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.string(forType: .kelpTab) != nil else {
            guard !Workbench.files(sender).isEmpty else { return [] }
            showHint(nil)
            return .copy
        }
        if let outer = outerEdge(sender) {
            hint.hide()
            showOuterHint?(outer)
            return .move
        }
        showOuterHint?(nil)
        showHint(edge(sender))
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        hint.hide()
        showOuterHint?(nil)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hint.hide()
        showOuterHint?(nil)
        guard let id = sender.draggingPasteboard.string(forType: .kelpTab) else {
            let files = Workbench.files(sender)
            onDropFiles?(files)
            return !files.isEmpty
        }
        if let outer = outerEdge(sender) {
            onDropOuter?(id, outer)
            return true
        }
        onDropTab?(id, edge(sender))
        return true
    }
}

/// Paints over the content without taking its clicks.
private class Veil: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSRect {
    /// The `fraction` of the rect along `edge`'s side, starting at that edge: where a dropped tab's pane goes.
    func share(_ fraction: CGFloat, from edge: NSRectEdge) -> NSRect {
        let across = edge == .minX || edge == .maxX ? width : height
        return divided(atDistance: across * fraction, from: CGRectEdge(rawValue: UInt32(edge.rawValue)) ?? .minXEdge)
            .slice
    }
}

/// Where a dropped tab will go (in a pane and at the editor area's outer edges), or a file in an agent's pane: accent
/// fill, accent border. It fades in where it's needed, glides from half to whole as the drop's insertion mark does,
/// and fades out in two thirds of that.
@MainActor
package final class DropHint: NSView {
    private var leaving = false
    /// Where a drop on a whole pane shows: the pane, a little in from its edges.
    static func across(_ pane: NSRect) -> NSRect { pane.insetBy(dx: 6, dy: 6) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.borderWidth = 1
        layer?.cornerRadius = Metrics.radiusSM
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows across the whole of `pane`, over everything in it: a file dragged over an agent's terminal.
    package func show(over pane: NSView) {
        if pane.subviews.last !== self { pane.addSubview(self) }
        show(Self.across(pane.bounds))
    }

    func show(_ place: NSRect) {
        leaving = false
        if isHidden {
            frame = place
            // Coloured as it shows, so it has the theme's accent and the appearance as they are now.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.fillTint(.themeAccent).cgColor
                layer?.borderColor = NSColor.themeAccent.withAlphaComponent(0.6).cgColor
            }
        } else if frame != place {   // every move of the pointer comes here
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.duration(Motion.fast)
                ctx.timingFunction = Motion.soft
                animator().frame = place
            }
        }
        fadeIn()
    }

    package func hide() {
        guard !isHidden, !leaving else { return }
        leaving = true
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = Motion.duration(Motion.fast * 2 / 3)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {   // AppKit runs the completion on the main thread
                    guard let self, self.leaving else { return }
                    self.isHidden = true
                    self.leaving = false
                }
            })
    }
}
