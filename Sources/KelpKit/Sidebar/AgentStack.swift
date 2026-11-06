import AppKit
import Core
import DesignKit

/// A folded project's or group's chats on its row: one agent logo each, side by side (logos on no tile ran together when
/// they overlapped), the most pressing first, its state in a corner cut out of the logo (none when it's only ready), as
/// macOS marks a person's status on their picture. Four at most, then "+N"; the tooltip names each and what it does.
@MainActor
final class AgentStack: NSView {
    private static let side: CGFloat = 14, step: CGFloat = 17, most = 4
    private let more = NSTextField(labelWithString: "")
    private var faces: [NSView] = []
    private var total = 0
    /// How many logos the row has room for (SidebarCell.fitBadges): the rest are counted in "+N".
    var cap = 4 { didSet { if cap != oldValue { place() } } }
    /// What was drawn last: a status change re-reads the row, and the marks keep spinning rather than being made again.
    private var shown: [String] = []

    init() {
        super.init(frame: .zero)
        more.font = .uiDigits(11, weight: .medium)
        more.textColor = .secondaryLabelColor
        addSubview(more)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The chats under `n`: its own screen's, then its groups'.
    static func chats(under n: SidebarController.Node, _ app: AppModel) -> [Session] {
        n.children.flatMap { $0.children.isEmpty ? [$0] : $0.children }
            .compactMap { if case .agent(let id) = $0.kind { app.session(id) } else { nil } }
    }

    func show(_ chats: [Session], _ app: AppModel) {
        let rank: (AgentStatus) -> Int = { [.error: 0, .waiting: 0, .working: 1, .done: 2][$0] ?? 3 }
        let sorted = chats.enumerated().sorted { (rank(Self.badge($0.element) ?? .idle), $0.offset) < (rank(Self.badge($1.element) ?? .idle), $1.offset) }
            .map(\.element)
        let now = sorted.map { "\($0.agent ?? "") \(Self.badge($0).map { "\($0)" } ?? "") \($0.status == .paused)" }
        toolTip = sorted.map { app.catalog.displayName($0) + " · " + SidebarCell.shownStatus($0).words }.joined(separator: "\n")
        setAccessibilityLabel(toolTip)
        guard now != shown else { return }
        shown = now
        faces.forEach { $0.removeFromSuperview() }
        total = sorted.count
        faces = sorted.prefix(Self.most).map { face($0, app) }
        faces.forEach(addSubview)
        place()
    }

    /// The width it takes showing `k` logos, "+N" after them for the rest.
    func width(showing k: Int) -> CGFloat {
        let k = min(k, faces.count)
        guard k > 0 else { return 0 }
        let rest = total - k, label = rest > 0 ? NSAttributedString(string: "+\(rest)", attributes: [.font: more.font as Any]).size().width + 4 : 0
        return Self.side + CGFloat(k - 1) * Self.step + 2 + ceil(label)
    }
    var count: Int { faces.count }

    private func place() {
        let shown = min(cap, faces.count)
        for (i, f) in faces.enumerated() { f.isHidden = i >= shown }
        more.stringValue = total > shown && shown > 0 ? "+\(total - shown)" : ""
        more.isHidden = more.stringValue.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Asking, failed, working, or done and not looked at: what earns a mark in the corner.
    private static func badge(_ s: Session) -> AgentStatus? {
        let st = SidebarCell.shownStatus(s)
        return [.waiting, .error, .working].contains(st) || (st == .done && s.unread) ? st : nil
    }

    private func face(_ s: Session, _ app: AppModel) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        let logo = NSImageView(frame: v.bounds)
        logo.imageScaling = .scaleProportionallyUpOrDown
        let image = app.catalog.icon(s.agent, size: Self.side)
        logo.image = s.status == .paused ? image.map(app.agentIcons.grey) : image
        v.addSubview(logo)
        if let st = Self.badge(s) {
            let mark = StatusMark(size: 8)
            mark.status = st
            mark.unread = true
            mark.announces = false
            mark.frame = NSRect(x: Self.side - 6, y: -2, width: 8, height: 8)
            // The logo gives way around the mark: a clear ring, whatever the sidebar's material shows through.
            logo.wantsLayer = true
            let cut = CAShapeLayer(), hole = CGPath(ellipseIn: mark.frame.insetBy(dx: -1.5, dy: -1.5), transform: nil)
            let path = CGMutablePath()
            path.addRect(logo.bounds)
            path.addPath(hole)
            cut.path = path
            cut.fillRule = .evenOdd
            logo.layer?.mask = cut
            v.addSubview(mark)
        }
        return v
    }

    override var intrinsicContentSize: NSSize { NSSize(width: width(showing: cap), height: Self.side) }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.side) / 2
        for (i, f) in faces.enumerated() { f.setFrameOrigin(NSPoint(x: CGFloat(i) * Self.step, y: y)) }
        let x = CGFloat(max(min(cap, faces.count) - 1, 0)) * Self.step + Self.side + 6
        more.frame = NSRect(x: x, y: (bounds.height - more.intrinsicContentSize.height) / 2, width: more.intrinsicContentSize.width,
                            height: more.intrinsicContentSize.height)
    }
}
