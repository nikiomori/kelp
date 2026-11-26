import AppKit
import Core
import DesignKit
import SwiftUI

/// The window's split view. Its dividers aren't drawn, because the panels and the gap round the card are one surface,
/// and each divider can be dragged across that gap too, not only at the panel's edge.
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
        if index > 0 { rect.origin.x -= Card.gap }   // reaches into the gap, which is on the editor area's side
        return rect
    }
    private final class Seamless: NSSplitView { override var dividerColor: NSColor { .clear } }
}

/// The place that holds a hiding panel (auto-hide, focus mode). It keeps the panel while the panel is away and, when
/// the pointer reaches the window's edge, brings it in over the editor area with rounded corners and a shadow, as Arc's
/// sidebar does. The panel sits `inset` from the window's edges.
@MainActor
final class Floater: NSView {
    private static let radius = Metrics.radiusXL
    let inset: CGFloat
    /// What holds the panel, with the theme's colour (`tint`) under it.
    let box = NSView()
    let tint = NSView()
    /// The material under `box`. It is the material of the window's surface or, in a theme that uses macOS's own
    /// material, Liquid Glass (macOS 26), which blurs the code and terminals the panel slides over instead of the
    /// desktop behind the window. A theme with a colour of its own keeps that colour. Reduce Transparency makes both
    /// opaque.
    private let material = NSVisualEffectView()
    private var glass: NSView?
    private var glassy: Bool?
    private var widthC: NSLayoutConstraint?
    private var leading = true
    private var shown = false
    private var slides = 0
    /// Where the floater's width is kept between launches. The column it took the width from starts collapsed when the
    /// panel hides.
    private let autosave: String
    var width: CGFloat {
        didSet {
            widthC?.constant = width
            UserDefaults.standard.set(Double(width), forKey: autosave)
        }
    }

    init(width: CGFloat, inset: CGFloat, autosave: String) {
        let saved = UserDefaults.standard.double(forKey: autosave)
        self.width = saved > 0 ? saved : width
        self.autosave = autosave
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
        guard on != glassy else { return }   // moving `box` needlessly would take the focus from the panel in it
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

    /// Attaches the floater to the window's leading or trailing edge, at full height. It is out of sight until it
    /// slides in.
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

    /// Slides the floater in or out. The view stands where it shows and only its layer travels, from past the window's
    /// edge and back, because when its constraint moved it, the window was laid out again for every frame of the way.
    /// It comes in on a spring (`Motion.slideIn`) and goes out in `Motion.fast`. `carrying` travel on it the same way
    /// (the traffic lights on the sidebar, as Arc's do), and are hidden with it.
    func slide(in on: Bool, animated: Bool = true, carrying: [NSView] = []) {
        guard let layer, widthC != nil, on != shown else { return }
        shown = on
        slides += 1
        let turn = slides   // a slide cut short still ends later, so only the last one hides the panel
        let away = (leading ? -1 : 1) * (width + 2 * inset + 20)   // far enough that the shadow is out of sight too
        let key = "transform.translation.x"
        let now = isHidden ? away : layer.presentation()?.value(forKeyPath: key) as? CGFloat ?? (on ? away : 0)
        let views = [self] + carrying
        views.forEach { $0.layer?.removeAnimation(forKey: "slide") }
        guard animated, !Motion.reduced else {
            views.forEach { $0.isHidden = !on }
            return
        }
        // It comes in on a spring, a little past its place and back; it leaves speeding up.
        let move: CABasicAnimation = on ? Motion.slideIn(key) : CABasicAnimation(keyPath: key)
        move.fromValue = now
        move.toValue = on ? 0 : away
        if !on {   // the floater stays out of sight until it's hidden
            move.duration = Motion.fast
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {   // Core Animation runs the completion block on the main thread
                guard let self, !self.shown, turn == self.slides else { return }
                for view in views {
                    view.isHidden = true
                    view.layer?.removeAnimation(forKey: "slide")
                }
            }
        }
        for view in views {
            view.wantsLayer = true
            view.isHidden = false
            view.alphaValue = 1
            view.layer?.add(move, forKey: "slide")
        }
        CATransaction.commit()
    }
    /// Whether `view` is travelling with a floater now, so nothing else moves or fades it meanwhile.
    static func carries(_ view: NSView) -> Bool { view.layer?.animation(forKey: "slide") != nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        material.layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.shadowColor.cgColor
        layer?.shadowOpacity = material.isHidden ? 0 : 0.3   // glass draws its own shadow
        layer?.shadowRadius = 14
        layer?.shadowOffset = .zero
    }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }
}

/// The editor area's card. It is rounded, with a hairline round it, and set in from the panels and the window's edges,
/// so the panels and the window bar read as one surface round it.
@MainActor
final class Card: NSView {
    static let gap: CGFloat = 6
    var look = WindowLook() { didSet { needsDisplay = true } }
    /// The desktop in dots under the editors, in a `halftone` theme.
    private var halftone: Halftone?
    /// Watches the window move, change screens and come back to the front, for the dots to line up with the desktop
    /// (and take a new picture). The observers are removed with the window or the view.
    private var observers: [NSObjectProtocol] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (look.card ?? .windowBackgroundColor).cgColor
        layer?.borderColor = (look.border ?? .separatorColor).cgColor
        layer?.borderWidth = look.borderWidth
        layer?.cornerRadius = look.radius
        showHalftone()
    }
    override func layout() {
        super.layout()
        halftone?.place(in: self, base: look.card ?? .black)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let names = [
            (NSWindow.didMoveNotification, window), (NSWindow.didChangeScreenNotification, window),
            (NSApplication.didBecomeActiveNotification, nil)
        ]
        observers = names.map { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }   // queue: .main
            }
        }
    }

    /// Adds the dots under the editors when the theme has them, and takes them away when it hasn't.
    private func showHalftone() {
        guard look.ambient?.kind == .halftone else {
            halftone?.dots.removeFromSuperlayer()
            halftone?.shade.removeFromSuperlayer()
            halftone = nil
            return
        }
        if halftone == nil {
            let made = Halftone()
            layer?.insertSublayer(made.dots, at: 0)
            layer?.insertSublayer(made.shade, above: made.dots)
            halftone = made
        }
        needsLayout = true
    }
}

extension NSButton {
    /// An icon button for the title bar: 14 pt, greyed in under the pointer like every Kelp control.
    static func titlebar(_ symbol: String, _ label: String, tip: String) -> PointerButton {
        // greys in under the pointer, springs when clicked, as every Kelp control
        let button = PointerButton(frame: .zero)
        button.image = .symbol(symbol, label, size: Metrics.segmentPoint)
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.symbolConfiguration = .chrome(Metrics.segmentPoint)
        return button
    }
}

/// A strip at the window's edge that reports the pointer resting there (focus mode's way back to the panels). The
/// pointer stays `Motion.edgeRest` before it counts, so passing over the edge on the way elsewhere brings nothing.
@MainActor
final class EdgeTrigger: NSView {
    var onEnter: (() -> Void)?
    private let rest = Debounce()
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { rest.after(Motion.edgeRest) { [weak self] in self?.onEnter?() } }
    override func mouseExited(with event: NSEvent) { rest.cancel() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to whatever is under it
}

/// The window's surface, in the sidebar's material. The panels and the gap round the editor area are this view.
/// Files and folders dropped where nothing else takes them (the empty workspace, the window bar, the inspector) are
/// handled as if dropped on the Dock icon.
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
        // Where the desktop shows through, it stays clear while the window is in the background too.
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
