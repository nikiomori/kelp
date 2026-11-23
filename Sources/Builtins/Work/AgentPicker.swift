import AppKit
import Core
import DesignKit

/// Whose touches to show: "All", then each agent that did something in what is shown, a kind of subagent as one entry
/// ("Explore ×12"). As segments when they fit the room left beside it, else as a menu, so it never sets how wide the
/// panel must be: a narrow inspector keeps its width.
@MainActor
final class AgentPicker: NSView {
    var onPick: (String?) -> Void = { _ in }

    /// One choice: a session's agent, or the subagents of one kind.
    struct Entry: Equatable {
        var key: String, label: String, members: Set<Int>
    }
    /// At the room's trailing edge (the panel's row) or its leading one (the Map tab's bar).
    var trailing = true
    private var entries: [Entry] = []
    private var segments = CapsuleSegments(labels: [], name: String(localized: "Agents"))
    private let popup = NSPopUpButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        popup.controlSize = .small
        popup.font = .ui(TextSize.caption)
        popup.target = self
        popup.action = #selector(picked(_:))
        addSubview(popup)
        // It takes the room it's given and asks for none: the stack beside it decides its width.
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        heightAnchor.constraint(equalToConstant: Metrics.segment.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// In the panel's row it asks for no width (it takes what is left); in the Map tab's bar it asks for its own.
    override var intrinsicContentSize: NSSize {
        guard !trailing else { return NSSize(width: NSView.noIntrinsicMetric, height: Metrics.segment.height) }
        let chosen: NSView = entries.count <= 3 ? segments : popup
        return NSSize(width: chosen.fittingSize.width, height: Metrics.segment.height)
    }

    /// The choices for `work`: each agent present (in its places or steps) in order, subagents grouped by kind.
    static func entries(_ work: AgentWork, names: [String]) -> [Entry] {
        var out: [Entry] = []
        for index in Set(work.places.flatMap(\.agents) + work.steps.map(\.agent)).sorted()
        where work.agents.indices.contains(index) {
            let agent = work.agents[index], name = names.indices.contains(index) ? names[index] : agent.name
            let key =
                agent.role == .subagent ? "kind:" + agent.name : "\(agent.role.rawValue):\(agent.id ?? agent.agent)"
            if let at = out.firstIndex(where: { $0.key == key }) {
                out[at].members.insert(index)
                out[at].label = "\(name) ×\(out[at].members.count)"
            } else {
                out.append(Entry(key: key, label: name, members: [index]))
            }
        }
        return out
    }

    func show(_ entries: [Entry], picked: String?) {
        isHidden = entries.count < 2
        if entries.map(\.label) != self.entries.map(\.label) || entries.map(\.key) != self.entries.map(\.key) {
            let labels = [String(localized: "All")] + entries.map(\.label)
            segments.removeFromSuperview()
            segments = CapsuleSegments(
                labels: labels, name: String(localized: "Agents"), target: self, action: #selector(picked(_:)))
            segments.controlSize = .small
            addSubview(segments)
            popup.removeAllItems()
            popup.addItems(withTitles: [String(localized: "All Agents")] + entries.map(\.label))
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
        self.entries = entries
        let index = picked.flatMap { key in entries.firstIndex { $0.key == key } }.map { $0 + 1 } ?? 0
        segments.selectedSegment = index
        popup.selectItem(at: index)
    }

    /// Segments when all of them fit, else the popup; either at the trailing edge.
    override func layout() {
        super.layout()
        let wide = segments.fittingSize, narrow = popup.fittingSize
        let fits = entries.count <= 3 && wide.width <= bounds.width
        segments.isHidden = !fits
        popup.isHidden = fits
        let size = fits ? wide : NSSize(width: min(narrow.width, bounds.width), height: narrow.height)
        let shown: NSView = fits ? segments : popup
        shown.frame = NSRect(
            x: trailing ? bounds.maxX - size.width : 0, y: (bounds.height - size.height) / 2, width: size.width,
            height: size.height)
    }

    @objc private func picked(_ sender: Any?) {
        let index =
            (sender as? CapsuleSegments)?.selectedSegment ?? (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0
        onPick(index <= 0 || index > entries.count ? nil : entries[index - 1].key)
    }
}
