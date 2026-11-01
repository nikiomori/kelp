import AppKit
import Core
import DesignKit

/// On an agent's row, the agents it started and its own subagents: the most urgent one's mark and how many, so they take no
/// rows of their own. Over it the hover card lists them; a click picks one, its tab opens (a subagent has none).
@MainActor
final class ChildrenBadge: PointerControl {
    private let app: AppModel
    private let mark = StatusMark(size: 12), count = NSTextField(labelWithString: "")
    private var kids: [Session] = [], subagents: [String] = []

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        count.font = .uiDigits(11, weight: .medium); count.textColor = .secondaryLabelColor
        let row = NSStackView(views: [mark, count])
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ kids: [Session], subagents: [String]) {
        self.kids = kids; self.subagents = subagents
        let n = kids.count + subagents.count
        isHidden = n == 0
        mark.status = AgentStatus.mostUrgent(kids.map(SidebarCell.shownStatus) + (subagents.isEmpty ? [] : [.working]))
        count.stringValue = "\(n)"
        setAccessibilityLabel(String(localized: "\(n) agents it started"))
    }

    override func clicked() {
        let m = NSMenu(), app = app
        for k in kids {
            let id = k.id
            m.add(app.catalog.displayName(k) + " · " + k.statusWords) { app.workbench.focus(session: id) }
        }
        for name in subagents { m.addItem(withTitle: name + " · " + AgentStatus.working.words, action: nil, keyEquivalent: "") }   // no action: greyed
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

extension SidebarCell {
    /// A row's second line: what it asks itself, or else what a child of its asks, under the child's name.
    static func line(_ s: Session, mode: String, among all: [Session]) -> (prefix: (String, NSColor)?, text: String)? {
        let own = askLine(s, mode: mode)
        guard own?.prefix == nil else { return own }
        for k in all.children(of: s.id) {
            if let line = askLine(k, mode: mode), let color = line.prefix?.1 { return ((k.displayTitle + ":", color), line.text) }
        }
        return own
    }
}

extension AppModel {
    /// "Fix login › reviewer" for a child, whose row is its parent's.
    func familyName(_ s: Session) -> String {
        let name = catalog.displayName(s)
        return s.parent.flatMap(session).map { catalog.displayName($0) + " › " + name } ?? name
    }
}
