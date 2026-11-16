import AppKit
import Core
import DesignKit

/// A folded project's or group's chats on its row: one agent logo each, side by side (logos on no tile ran together when
/// they overlapped), the most pressing first, its state in a corner cut out of the logo (none when it's only ready), as
/// macOS marks a person's status on their picture. Four at most, then "+N"; the tooltip names each and what it does.
/// A logo opens its chat; "+N" unfolds the row (`onMore`).
@MainActor
final class AgentStack: NSView {
    private static let side = AgentFace.side, step: CGFloat = 17, most = 4
    private let more = PointerButton(frame: .zero)
    private var faces: [PointerButton] = []
    /// "+N" clicked: the row opens to show the rest.
    var onMore: (() -> Void)?
    private var total = 0
    /// How many logos the row has room for (SidebarCell.fitBadges): the rest are counted in "+N".
    var cap = 4 { didSet { if cap != oldValue { place() } } }
    /// What was drawn last: a status change re-reads the row, and the marks keep spinning rather than being made again.
    private var shown: [String] = []

    init() {
        super.init(frame: .zero)
        more.font = .uiDigits(TextSize.caption, weight: .medium)
        more.radius = Metrics.radiusXS
        more.onClick = { [weak self] in self?.onMore?() }
        addSubview(more)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)   // its logos are buttons of their own
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The chats under `node`: its own screen's, then its groups'.
    static func chats(under node: SidebarController.Node, _ app: AppModel) -> [Session] {
        node.children.flatMap { $0.children.isEmpty ? [$0] : $0.children }
            .compactMap { if case .agent(let id) = $0.kind { app.session(id) } else { nil } }
    }

    func show(_ chats: [Session], _ app: AppModel) {
        let rank: (AgentStatus) -> Int = { [.error: 0, .waiting: 0, .working: 1, .done: 2][$0] ?? 3 }
        let sorted = chats.enumerated().sorted {
            (rank(Self.badge($0.element) ?? .idle), $0.offset) < (rank(Self.badge($1.element) ?? .idle), $1.offset)
        }
        .map(\.element)
        let now = sorted.map { "\($0.agent ?? "") \(Self.badge($0).map { "\($0)" } ?? "") \($0.status == .paused)" }
        toolTip = sorted.map { app.catalog.displayName($0) + " · " + $0.statusWords }.joined(
            separator: "\n")
        setAccessibilityLabel(toolTip)
        guard now != shown else { return }
        shown = now
        faces.forEach { $0.removeFromSuperview() }
        total = sorted.count
        faces = sorted.prefix(Self.most).map { face($0, app) }
        faces.forEach(addSubview)
        place()
    }

    /// The width `logos` logos take, "+N" after them for the rest.
    func width(showing logos: Int) -> CGFloat {
        let logos = min(logos, faces.count)
        guard logos > 0 else { return 0 }
        let rest = total - logos
        return Self.side + CGFloat(logos - 1) * Self.step + (rest > 0 ? Self.gap + labelWidth("+\(rest)") : 0)
    }
    /// Between the last logo and "+N".
    private static let gap: CGFloat = 4
    /// The room "+N" takes: its words and the 2 pt a label keeps on each side of them. Asked of the field, it came out
    /// as the words alone, and the last digit lost its right edge.
    private func labelWidth(_ words: String) -> CGFloat {
        ceil(NSAttributedString(string: words, attributes: [.font: more.font as Any]).size().width) + 4
    }
    var count: Int { faces.count }

    private func place() {
        let shown = min(cap, faces.count)
        for (index, logo) in faces.enumerated() { logo.isHidden = index >= shown }
        let words = total > shown && shown > 0 ? "+\(total - shown)" : ""
        more.attributedTitle = NSAttributedString(
            string: words, attributes: [.font: more.font as Any, .foregroundColor: NSColor.secondaryLabelColor])
        more.toolTip = words.isEmpty ? nil : String(localized: "Show All")
        more.isHidden = words.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Asking, failed, working, or done and not looked at: what earns a mark in the corner.
    private static func badge(_ session: Session) -> AgentStatus? {
        let st = SidebarCell.shownStatus(session)
        return [.waiting, .error, .working].contains(st) || (st == .done && session.unread) ? st : nil
    }

    /// A logo that opens its chat, as picking its row would; a round grey under the pointer, a little wider than the logo.
    private func face(_ session: Session, _ app: AppModel) -> PointerButton {
        let face = AgentFace()
        let image = app.catalog.icon(session.agent, size: Self.side)
        face.image = session.status == .paused ? image.map(app.agentIcons.grey) : image
        face.mark.status = Self.badge(session)
        face.mark.unread = true
        face.cut()
        let id = session.id
        let button = PointerButton { [weak app] in
            app?.workbench.focus(session: id)
            app?.arrangement.parkedBack[id] = nil   // opened: its "Back:" line has been read
        }
        // Round, and not clipped to that circle: it cut the state mark in the logo's corner. AppKit turns clipping back on
        // whenever the radius changes, so the radius is set for good first.
        button.radius = Self.hit / 2
        button.layer?.cornerRadius = Self.hit / 2
        button.clipsToBounds = false
        button.frame.size = NSSize(width: Self.hit, height: Self.hit)
        face.setFrameOrigin(NSPoint(x: (Self.hit - Self.side) / 2, y: (Self.hit - Self.side) / 2))
        button.addSubview(face)
        button.toolTip = app.catalog.displayName(session) + " · " + session.statusWords
        button.setAccessibilityLabel(button.toolTip)
        return button
    }
    /// A logo's button: its fill shows around the logo, and the logos still sit `step` apart.
    private static let hit: CGFloat = 18

    override var intrinsicContentSize: NSSize { NSSize(width: width(showing: cap), height: Self.side) }

    override func layout() {
        super.layout()
        let top = (bounds.height - Self.side) / 2
        let inset = (Self.hit - Self.side) / 2
        for (index, face) in faces.enumerated() {
            face.setFrameOrigin(NSPoint(x: CGFloat(index) * Self.step - inset, y: top - inset))
        }
        let moreX = CGFloat(max(min(cap, faces.count) - 1, 0)) * Self.step + Self.side + Self.gap
        more.frame = NSRect(
            x: moreX, y: (bounds.height - Self.hit) / 2, width: labelWidth(more.title), height: Self.hit)
    }
}
