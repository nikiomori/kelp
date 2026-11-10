import AppKit
import Core
import DesignKit
import SwiftUI
import WorkbenchKit

/// The window's split: its dividers aren't drawn (the panels and the gap round the card are one surface), and each can
/// be dragged across that gap too, not only at the panel's edge.
@MainActor
final class ShellSplit: NSSplitViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        let seamless = Seamless()
        seamless.isVertical = true
        seamless.dividerStyle = .thin
        splitView = seamless
    }
    required init?(coder: NSCoder) { fatalError() }
    override func splitView(
        _ split: NSSplitView, effectiveRect proposed: NSRect, forDrawnRect drawn: NSRect, ofDividerAt index: Int
    ) -> NSRect {
        var rect = super.splitView(split, effectiveRect: proposed, forDrawnRect: drawn, ofDividerAt: index)
        rect.size.width += Card.gap
        if index > 0 { rect.origin.x -= Card.gap }   // into the gap, which is on the editor area's side
        return rect
    }
    private final class Seamless: NSSplitView { override var dividerColor: NSColor { .clear } }
}

/// A hiding panel's place (auto-hide, focus mode): it holds the panel while it's away and, at the window's edge, brings
/// it in over the editor area with rounded corners and a shadow, as Arc's sidebar does: `inset` clear of the window's
/// edges, or flush with them (the sidebar's, where the traffic lights are: 6 pt in, they sat on its corner with a strip
/// of window round them).
@MainActor
final class Floater: NSView {
    private static let radius: CGFloat = 12
    private let inset: CGFloat
    /// What holds the panel, with the theme's colour (`tint`) under it.
    let box = NSView()
    let tint = NSView()
    /// Under `box`: the material the window's surface is or, in a theme on macOS's own material, Liquid Glass (macOS 26),
    /// which blurs the code and terminals the panel slides over rather than the desktop behind the window. A theme with a
    /// colour of its own keeps that colour; Reduce Transparency makes both opaque.
    private let material = NSVisualEffectView()
    private var glass: NSView?
    private var glassy: Bool?
    private var widthC: NSLayoutConstraint?
    private var leading = true
    private var shown = false
    private var slides = 0
    var width: CGFloat { didSet { widthC?.constant = width } }

    init(width: CGFloat, inset: CGFloat) {
        self.width = width
        self.inset = inset
        super.init(frame: .zero)
        isHidden = true
        wantsLayer = true
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.wantsLayer = true
        material.layer?.borderWidth = 1
        box.wantsLayer = true
        for layered in [material, box] {
            layered.layer?.cornerRadius = Self.radius
            layered.layer?.cornerCurve = .continuous
            layered.layer?.masksToBounds = true
        }
        pin(material)
        tint.wantsLayer = true
        box.pin(tint)
        show(WindowLook())
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ look: WindowLook) {
        tint.layer?.backgroundColor = look.surface?.cgColor
        let on = look.surface == nil
        guard on != glassy else { return }   // moving `box` would take the focus from the panel in it
        glassy = on
        box.removeFromSuperview()
        if on, #available(macOS 26, *) {
            let glassView = glass as? NSGlassEffectView ?? NSGlassEffectView()
            if glass == nil {
                glassView.cornerRadius = Self.radius
                pin(glassView)
                glass = glassView
            }
            glassView.contentView = box
        } else {
            if #available(macOS 26, *) { (glass as? NSGlassEffectView)?.contentView = nil }
            pin(box)
        }
        material.isHidden = glass != nil && on
        glass?.isHidden = !material.isHidden
        needsDisplay = true
    }

    /// Against the window's leading or trailing edge, its full height; out of sight until it slides in.
    func attach(leading: Bool) {
        guard let parent = superview else { return }
        self.leading = leading
        let pinned =
            leading
            ? leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset)
            : parent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: inset)
        let sized = widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            pinned, sized, topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
        widthC = sized
    }

    /// It stands where it shows and only its layer travels, from past the window's edge and back: moved by its
    /// constraint, the window was laid out again for every frame of the way. It goes in two thirds of the time it
    /// took to come in.
    func slide(in on: Bool, animated: Bool = true) {
        guard let layer, widthC != nil, on != shown else { return }
        shown = on
        slides += 1
        let turn = slides   // a slide cut short ends too, later: only the last one hides the panel
        let away = (leading ? -1 : 1) * (width + 2 * inset + 20)   // the shadow out of sight too
        let key = "transform.translation.x"
        let now = isHidden ? away : layer.presentation()?.value(forKeyPath: key) as? CGFloat ?? (on ? away : 0)
        layer.removeAnimation(forKey: "slide")
        guard animated, !Motion.reduced else {
            isHidden = !on
            return
        }
        isHidden = false
        let move = CABasicAnimation(keyPath: key)
        move.fromValue = now
        move.toValue = on ? 0 : away
        move.duration = on ? Motion.base : Motion.fast
        move.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
        if !on {   // it stays out of sight until it's hidden
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {   // Core Animation runs it on the main thread
                guard let self, !self.shown, turn == self.slides else { return }
                self.isHidden = true
                self.layer?.removeAnimation(forKey: "slide")
            }
        }
        layer.add(move, forKey: "slide")
        CATransaction.commit()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        material.layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.shadowColor.cgColor
        layer?.shadowOpacity = material.isHidden ? 0 : 0.3   // glass draws its own
        layer?.shadowRadius = 14
        layer?.shadowOffset = .zero
    }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }
}

/// The editor area's card: rounded, a hairline round it, in from the panels and the window's edges, so the panels and
/// the window bar read as one surface round it.
@MainActor
final class Card: NSView {
    static let gap: CGFloat = 6
    var look = WindowLook() { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (look.card ?? .windowBackgroundColor).cgColor
        layer?.borderColor = (look.border ?? .separatorColor).cgColor
        layer?.borderWidth = look.borderWidth
        layer?.cornerRadius = look.radius
    }
}

extension NSButton {
    /// An icon button for the title bar: 14 pt, greyed in under the pointer like every Kelp control.
    static func titlebar(_ symbol: String, _ label: String, tip: String) -> PointerButton {
        // greys in under the pointer, springs when clicked, as every Kelp control
        let button = PointerButton(frame: .zero)
        button.image = .symbol(symbol, label)
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.symbolConfiguration = .chrome(Metrics.segmentPoint)
        return button
    }
}

/// A strip at the window's edge that reports the pointer arriving (focus mode's way back to the panels).
@MainActor
final class EdgeTrigger: NSView {
    var onEnter: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to whatever is under it
}

/// The window's surface, in the sidebar's material: the panels and the gap round the editor area are this.
/// Files and folders dropped where nothing else takes them (the empty workspace, the window bar, the inspector): as if
/// dropped on the Dock icon.
@MainActor
final class DropRoot: NSVisualEffectView {
    private let app: AppModel
    private let backdrop = Backdrop()
    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        pin(backdrop)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ look: WindowLook) {
        backdrop.show(look)
        // What the desktop shows through stays clear with the window in the background too.
        state = look.solid ? .inactive : look.seeThrough ? .active : .followsWindowActiveState
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Workbench.files(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = Workbench.files(sender)
        app.workbench.open(files: files)
        return !files.isEmpty
    }
}
