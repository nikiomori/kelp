import AppKit
import Core
import DesignKit

/// The chats of a folded project or group, shown on its row. Each chat that is at work or waiting for you (asking,
/// failed, working, done and not looked at) gets a logo, the most pressing first, with its state in a corner cut out of
/// the logo, as macOS marks a person's status on their picture. There are two logos at most, then "+N" for the rest.
/// When no chat qualifies, only the chats' count shows (four ready logos said less than a number). The tooltip names
/// each chat and what it does. A logo opens its chat, and the number unfolds the row (`onMore`).
@MainActor
final class AgentStack: NSView {
    private static let side = AgentFace.side, step: CGFloat = 17, most = 2
    private let more = PointerButton(frame: .zero)
    private var faces: [PointerButton] = []
    /// Called when "+N" is clicked, so the row opens to show the rest.
    var onMore: (() -> Void)?
    /// The number of all the chats, with a logo or not.
    private(set) var total = 0
    /// How many logos the row has room for (SidebarCell.fitBadges). The rest are counted in "+N".
    var cap = 4 { didSet { if cap != oldValue { place() } } }
    /// What was drawn last. A status change re-reads the row, and when nothing changed the marks keep spinning instead
    /// of being made again.
    private var shown: [String] = []

    init() {
        super.init(frame: .zero)
        more.font = .uiDigits(TextSize.caption, weight: .medium)
        more.radius = Metrics.radiusXS
        more.onClick = { [weak self] in self?.onMore?() }
        addSubview(more)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)   // the logos are buttons of their own
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The chats under `node`: those of its own screen first, then those of its groups.
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
        faces = sorted.filter { Self.badge($0) != nil }.prefix(Self.most).map { face($0, app) }
        faces.forEach(addSubview)
        place()
    }

    /// The width that `logos` logos take, with "+N" after them for the rest. With no logo, it is the width of the
    /// count alone.
    func width(showing logos: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        let logos = min(logos, faces.count), rest = total - logos
        guard logos > 0 else { return labelWidth(Self.words(logos: 0, total: total)) }
        return Self.side + CGFloat(logos - 1) * Self.step + (rest > 0 ? Self.gap + labelWidth("+\(rest)") : 0)
    }
    /// The words after the logos: the rest ("+4"), or all of them ("5") when no logo is shown.
    private static func words(logos: Int, total: Int) -> String {
        total <= logos ? "" : logos > 0 ? "+\(total - logos)" : "\(total)"
    }
    /// The gap between the last logo and "+N".
    private static let gap: CGFloat = 4
    /// The room "+N" takes: its words and the 2 pt a label keeps on each side of them. The field's own measure came out
    /// as the words alone, and the last digit lost its right edge.
    private func labelWidth(_ words: String) -> CGFloat {
        ceil(NSAttributedString(string: words, attributes: [.font: more.font as Any]).size().width) + 4
    }
    var count: Int { faces.count }

    private func place() {
        let shown = min(cap, faces.count)
        for (index, logo) in faces.enumerated() { logo.isHidden = index >= shown }
        let words = Self.words(logos: shown, total: total)
        more.attributedTitle = NSAttributedString(
            string: words, attributes: [.font: more.font as Any, .foregroundColor: NSColor.secondaryLabelColor])
        more.toolTip = words.isEmpty ? nil : String(localized: "Show All")
        more.isHidden = words.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The state that earns a mark in the corner: asking, failed, working, or done and not looked at.
    private static func badge(_ session: Session) -> AgentStatus? {
        let st = session.shownStatus
        return [.waiting, .error, .working].contains(st) || (st == .done && session.unread) ? st : nil
    }

    /// Makes a logo that opens its chat, as selecting its row would. Under the pointer it shows a round grey, a little
    /// wider than the logo.
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
            app?.arrangement.parkedBack[id] = nil   // once opened, its "Back:" line has been read
        }
        // The button is round but not clipped to that circle, because clipping cut the state mark in the logo's
        // corner. AppKit turns clipping back on whenever the radius changes, so the radius is set for good first.
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
    /// The size of a logo's button. Its fill shows around the logo, and the logos still sit `step` apart.
    private static let hit: CGFloat = 18

    override var intrinsicContentSize: NSSize { NSSize(width: width(showing: cap), height: Self.side) }

    override func layout() {
        super.layout()
        let top = (bounds.height - Self.side) / 2
        let inset = (Self.hit - Self.side) / 2
        for (index, face) in faces.enumerated() {
            face.setFrameOrigin(NSPoint(x: CGFloat(index) * Self.step - inset, y: top - inset))
        }
        let shown = min(cap, faces.count)
        let moreX = shown > 0 ? CGFloat(shown - 1) * Self.step + Self.side + Self.gap : 0
        more.frame = NSRect(
            x: moreX, y: (bounds.height - Self.hit) / 2, width: labelWidth(more.title), height: Self.hit)
    }
}
