import AppKit
import DesignKit
import KelpKit

/// A push button with a menu: the menu's arrow inside its capsule behind a hairline, as VS Code's Commit, not a second
/// capsule beside it (two capsules read as two actions). macOS's NSComboButton would do it, but takes no accent tint.
@MainActor
final class SplitPushButton: NSButton {
    /// Opens the menu (its own target and action).
    let arrow = NSButton()
    private let divider = NSView()
    private var keyWatch: [NSObjectProtocol] = []
    private let glow = EdgeGlow(radius: Metrics.radiusSM, spread: 4, strength: 0.7)
    private let ring = StatusMark(size: 12)
    /// What the button's action is doing. The state is light along its edge, as a tab's and a pane's are, with the words
    /// on the button saying which; a ring turns in the capsule while it goes on.
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
    /// The words change in a fade, the capsule keeping its place.
    func say(_ words: String) {
        guard words != title else { return }
        if window != nil { crossfade() }
        title = words
    }
    /// The accent fill (macOS 26's primary tint): the panel's main action while it has something to do.
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
        controlSize = .large
        arrow.image = .symbol("chevron.down", arrowTip)
        arrow.toolTip = arrowTip
        arrow.isBordered = false
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

    /// White on the accent fill, as the title is; the label's colour where the capsule is grey (nothing to do, disabled,
    /// another window in front, before macOS 26).
    private func tint() {
        var filled = false
        if #available(macOS 26, *) { filled = primary && isEnabled && window?.isKeyWindow == true }
        arrow.contentTintColor = filled ? .white : .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = (filled ? NSColor.white.withAlphaComponent(0.35) : .separatorColor).cgColor
        }
    }

    /// The capsule, not the frame around it, follows the glow.
    override func layout() {
        super.layout()
        glow.frame = alignmentRect(forFrame: frame).offsetBy(dx: -frame.origin.x, dy: -frame.origin.y)
        glow.radius = glow.frame.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }
    /// The accent fill goes grey while another window is in front: the arrow follows.
    override func viewWillMove(toWindow w: NSWindow?) {
        super.viewWillMove(toWindow: w)
        keyWatch.forEach(NotificationCenter.default.removeObserver)
        keyWatch =
            w == nil
            ? []
            : [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tint() }   // queue: .main
                }
            }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tint()
    }
}

/// The title centred in the part left of the arrow, not across the whole capsule (where it leaned into the arrow), and
/// the arrow's room counted in the button's width.
private final class SplitCell: NSButtonCell {
    static let reserve: CGFloat = 32   // the arrow (26), its gap and the hairline
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in view: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.offsetBy(dx: -Self.reserve / 2, dy: 0), in: view)
    }
    override var cellSize: NSSize {
        var s = super.cellSize
        s.width += Self.reserve
        return s
    }
}
