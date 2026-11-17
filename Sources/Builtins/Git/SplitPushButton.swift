import AppKit
import DesignKit
import KelpKit

/// A push button with a menu. The menu's arrow sits inside the button's capsule behind a hairline, as in VS Code's
/// Commit, not in a second capsule beside it, because two capsules read as two actions. macOS's NSComboButton would
/// do it, but takes no accent tint.
@MainActor
final class SplitPushButton: NSButton {
    /// Opens the menu, with its own target and action.
    let arrow = PointerButton(frame: .zero)
    private let divider = NSView()
    private var keyWatch: [NSObjectProtocol] = []
    private let glow = EdgeGlow(radius: Metrics.radiusSM, spread: 4, strength: 0.7)
    private let ring = StatusMark(size: 12)
    /// What the button's action is doing. The state shows as light along the button's edge, as on a tab or a pane, and
    /// the words on the button say which state it is. A ring turns in the capsule while the action runs.
    enum Work { case none, running, done, failed }
    var work = Work.none {
        didSet {
            guard work != oldValue else { return }
            ring.status = work == .running ? .working : nil
            switch work {
            case .none: glow.show(nil, breathing: false)
            case .running: glow.show(.themeAccent, breathing: true)
            case .done: glow.show(.systemGreen, breathing: false)
            case .failed:
                glow.show(.systemRed, breathing: false)
                shake()
            }
            tint()
        }
    }
    /// Changes the words with a fade, while the capsule keeps its place.
    func say(_ words: String) {
        guard words != title else { return }
        if window != nil { crossfade() }
        title = words
    }
    /// The accent fill (macOS 26's primary tint), for the panel's main action while it has something to do.
    var primary = false {
        didSet {
            if #available(macOS 26, *) { tintProminence = primary ? .primary : .automatic }
            tint()
        }
    }
    override var isEnabled: Bool {
        didSet {
            arrow.isEnabled = isEnabled
            tint()
        }
    }
    override static var cellClass: AnyClass? {
        get { SplitCell.self }
        set { _ = newValue }
    }

    convenience init(title: String, arrowTip: String) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        controlSize = .regular   // a rounded rectangle, as the Message field over it, because large is a capsule
        arrow.image = .symbol("chevron.down", arrowTip)
        arrow.toolTip = arrowTip
        arrow.symbolConfiguration = .chrome()
        divider.wantsLayer = true
        for v in [arrow, divider, ring] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        addSubview(glow)
        NSLayoutConstraint.activate([
            arrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 26), arrow.heightAnchor.constraint(equalToConstant: 22),
            divider.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -2),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 16),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        tint()
    }

    /// Colours the arrow white on the accent fill, as the title is, and in the label's colour where the capsule is
    /// grey (nothing to do, disabled, another window in front, or before macOS 26).
    private func tint() {
        var filled = false
        if #available(macOS 26, *) { filled = primary && isEnabled && window?.isKeyWindow == true }
        arrow.contentTintColor = filled ? .white : .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = (filled ? NSColor.white.withAlphaComponent(0.35) : .separatorColor).cgColor
        }
    }

    /// The glow follows the capsule, not the frame around it.
    override func layout() {
        super.layout()
        glow.frame = alignmentRect(forFrame: frame).offsetBy(dx: -frame.origin.x, dy: -frame.origin.y)
        glow.radius = glow.frame.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }
    /// The accent fill goes grey while another window is in front, and the arrow follows it.
    override func viewWillMove(toWindow window: NSWindow?) {
        super.viewWillMove(toWindow: window)
        keyWatch.forEach(NotificationCenter.default.removeObserver)
        keyWatch =
            window == nil
            ? []
            : [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tint() }   // queue: .main
                }
            }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tint()
    }
}

/// Centres the title in the part left of the arrow, not across the whole capsule (where it leaned into the arrow), and
/// counts the arrow's room in the button's width.
private final class SplitCell: NSButtonCell {
    static let reserve: CGFloat = 32   // the arrow (26), its gap and the hairline
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in view: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.offsetBy(dx: -Self.reserve / 2, dy: 0), in: view)
    }
    override var cellSize: NSSize {
        var size = super.cellSize
        size.width += Self.reserve
        return size
    }
}
