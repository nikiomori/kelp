import AppKit
import DesignKit

/// One editor group: its tab strip over the selected tab's content. Dropping a tab on an edge splits the group.
@MainActor
final class GroupView: NSView {
    let groupId: String
    let strip = TabStrip()
    private let container = NSView()
    private let hint = GroupView.dropHint()
    private weak var shown: NSView?
    private let veil = Veil()
    private let ring = Glow()
    /// A glow inside the content's edges when its agent calls for you (it clears once you've looked or answered).
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
    /// Dropped right at an outer side of the whole editor area: a split along all of it.
    var onDropOuter: ((String, NSRectEdge) -> Void)?
    /// The editor area's frame in window coordinates, and a hint drawn across it (nil: none).
    var editorFrame: (() -> NSRect?)?
    var showOuterHint: ((NSRectEdge?) -> Void)?
    /// A terminal pane without focus, among several: it fades toward the terminal's background (Ghostty does the same).
    var dimmed = false {
        didSet {
            guard dimmed != oldValue else { return }
            veil.layer?.backgroundColor = themes.terminalBackground.withAlphaComponent(0.3).cgColor
            veil.isHidden = !dimmed
        }
    }

    private let themes: ThemeManager

    init(groupId: String, themes: ThemeManager) {
        self.groupId = groupId; self.themes = themes
        super.init(frame: .zero)
        veil.wantsLayer = true; veil.isHidden = true
        for v in [strip, container, veil, ring] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        addSubview(hint)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor), strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: strip.bottomAnchor), container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor), container.bottomAnchor.constraint(equalTo: bottomAnchor),
            veil.topAnchor.constraint(equalTo: container.topAnchor), veil.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            veil.leadingAnchor.constraint(equalTo: container.leadingAnchor), veil.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ring.topAnchor.constraint(equalTo: container.topAnchor, constant: 1), ring.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            ring.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            ring.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -1)
        ])
        registerForDraggedTypes([.kelpTab, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where a dropped tab will go (here and at the editor area's outer edges): accent fill, accent border.
    static func dropHint() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.isHidden = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        v.layer?.borderWidth = 1
        v.layer?.cornerRadius = 6
        return v
    }

    func show(_ v: NSView?) {
        guard v !== shown || v?.superview !== container else { return }
        // Only if it's still here: a tab moved to another group took its view along.
        if shown?.superview === container {
            if v != nil { container.crossfade() }   // one tab's content fades into the next
            shown?.removeFromSuperview()
        }
        shown = v
        guard let v else { return }
        v.removeFromSuperview()
        container.pin(v)
    }

    // MARK: tab dropped on the content: an edge splits, the middle moves the tab here

    /// Within 18 pt of a side of this group that is also a side of the editor area.
    private func outerEdge(_ s: NSDraggingInfo) -> NSRectEdge? {
        guard let area = editorFrame?() else { return nil }
        let me = convert(bounds, to: nil), p = s.draggingLocation, near: CGFloat = 18
        if abs(me.minX - area.minX) < 1, p.x - me.minX < near { return .minX }
        if abs(me.maxX - area.maxX) < 1, me.maxX - p.x < near { return .maxX }
        if abs(me.maxY - area.maxY) < 1, me.maxY - p.y < near, p.y < me.maxY - strip.frame.height { return .maxY }
        if abs(me.minY - area.minY) < 1, p.y - me.minY < near { return .minY }
        return nil
    }
    private func edge(_ s: NSDraggingInfo) -> NSRectEdge? {
        let p = container.convert(s.draggingLocation, from: nil), b = container.bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let fx = p.x / b.width, fy = p.y / b.height
        let m = min(fx, 1 - fx, fy, 1 - fy)
        guard m < 0.25 else { return nil }
        if m == fx { return .minX }
        if m == 1 - fx { return .maxX }
        return m == fy ? .minY : .maxY
    }
    private func showHint(_ e: NSRectEdge?) {
        var r = container.frame.insetBy(dx: 6, dy: 6)
        switch e {
        case .minX?: r.size.width /= 2
        case .maxX?: r.origin.x += r.width / 2; r.size.width /= 2
        case .minY?: r.size.height /= 2
        case .maxY?: r.origin.y += r.height / 2; r.size.height /= 2
        default: break
        }
        hint.frame = r; hint.isHidden = false
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard s.draggingPasteboard.string(forType: .kelpTab) != nil else {
            guard !Workbench.files(s).isEmpty else { return [] }
            showHint(nil); return .copy
        }
        if let o = outerEdge(s) {
            hint.isHidden = true
            showOuterHint?(o)
            return .move
        }
        showOuterHint?(nil)
        showHint(edge(s))
        return .move
    }
    override func draggingExited(_ s: NSDraggingInfo?) { hint.isHidden = true; showOuterHint?(nil) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hint.isHidden = true; showOuterHint?(nil)
        guard let id = s.draggingPasteboard.string(forType: .kelpTab) else {
            let files = Workbench.files(s)
            onDropFiles?(files); return !files.isEmpty
        }
        if let o = outerEdge(s) { onDropOuter?(id, o); return true }
        onDropTab?(id, edge(s)); return true
    }
}

/// Paints over the content without taking its clicks.
private class Veil: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

/// The frame the glow is the shadow of: a band just outside `b`, its inner edge wound against the outer one.
enum GlowFrame {
    static func path(_ b: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(b.insetBy(dx: -40, dy: -40))
        path.addLines(between: [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY),
                                CGPoint(x: b.maxX, y: b.minY)])
        path.closeSubpath()
        return path
    }
}

/// A hairline and a soft glow inward from the edges: the shadow of a frame drawn just outside, clipped to the bounds.
private final class Glow: Veil {
    private let frameLayer = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true; isHidden = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Metrics.radiusSM
        layer?.borderWidth = 1
        frameLayer.fillRule = .evenOdd
        frameLayer.shadowOffset = .zero
        frameLayer.shadowRadius = 14
        frameLayer.shadowOpacity = 0.6
        layer?.addSublayer(frameLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var color: NSColor?

    /// Fades in and out, and eases into and out of breathing, rather than switching at once.
    func show(_ color: NSColor?, breathing: Bool) {
        self.color = color
        guard let color else {
            // Keeps its colour and breathing while it fades; hidden at the end unless it was called back meanwhile.
            NSAnimationContext.runAnimationGroup({ $0.duration = Motion.duration(Motion.disappear); animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {  // AppKit runs the completion on the main thread
                    guard let self, self.color == nil else { return }
                    self.isHidden = true
                    self.frameLayer.removeAllAnimations()
                }
            }
            return
        }
        if isHidden { alphaValue = 0; isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.duration(Motion.appear)
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1
            layer?.borderColor = color.withAlphaComponent(0.5).cgColor
            frameLayer.fillColor = color.cgColor; frameLayer.shadowColor = color.cgColor
        }
        breathe(breathing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func breathe(_ on: Bool) {
        let breathingNow = frameLayer.animation(forKey: "breathe") != nil
        guard on != breathingNow else { return }
        let opacity = frameLayer.presentation()?.opacity ?? 1
        frameLayer.removeAnimation(forKey: "breathe")
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = opacity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if on {
            a.toValue = 0.35
            a.duration = 1.2
            a.autoreverses = true
            a.repeatCount = .infinity
            frameLayer.add(a, forKey: "breathe")
        } else {
            // Back to full from wherever the breath was.
            a.toValue = 1
            a.duration = 0.3
            frameLayer.add(a, forKey: "settle")
        }
    }

    override func layout() {
        super.layout()
        // The inner edge runs the other way round from the outer one, so the hole stays a hole under the non-zero rule the
        // shadow path is filled with. Given as the shadow's path, the shadow isn't worked out from the layer's pixels
        // offscreen on every frame of the breathing animation.
        let path = GlowFrame.path(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        frameLayer.path = path
        frameLayer.shadowPath = path
        CATransaction.commit()
    }
}
