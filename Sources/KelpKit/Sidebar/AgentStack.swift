import AppKit
import Core
import DesignKit

/// A folded project's or group's chats on its row: one agent logo each, overlapping, the most pressing first, its state
/// in the corner (none when it's only ready). Four at most, then "+N"; the tooltip names each and what it does.
@MainActor
final class AgentStack: NSView {
    private static let side: CGFloat = 14, step: CGFloat = 12, most = 4
    private let more = NSTextField(labelWithString: "")
    private var faces: [NSView] = []
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
        let first = Array(sorted.prefix(Self.most))
        faces = first.map { face($0, app) }
        for f in faces.reversed() { addSubview(f) }   // the first on top: its corner mark stays clear of the next
        more.stringValue = sorted.count > Self.most ? "+\(sorted.count - Self.most)" : ""
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
            let disc = Disc(frame: NSRect(x: Self.side - 6, y: -4, width: 10, height: 10))
            let mark = StatusMark(size: 8)
            mark.status = st
            mark.unread = true
            mark.announces = false
            mark.frame = disc.bounds.insetBy(dx: 1, dy: 1)
            disc.addSubview(mark)
            v.addSubview(disc)
        }
        return v
    }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(faces.count)
        let w = n == 0 ? 0 : Self.side + (n - 1) * Self.step + 4 + (more.isHidden ? 0 : 3 + more.intrinsicContentSize.width)
        return NSSize(width: w, height: Self.side)
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.side) / 2
        for (i, f) in faces.enumerated() { f.setFrameOrigin(NSPoint(x: CGFloat(i) * Self.step, y: y)) }
        let x = faces.isEmpty ? 0 : CGFloat(faces.count - 1) * Self.step + Self.side + 7
        more.frame = NSRect(x: x, y: (bounds.height - more.intrinsicContentSize.height) / 2, width: more.intrinsicContentSize.width,
                            height: more.intrinsicContentSize.height)
    }
}

/// The round backing a corner mark sits on, in the window's colour, so it reads over the logo under it.
@MainActor
private final class Disc: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }   // follows the appearance
}
