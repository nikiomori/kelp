import AppKit
import Core
import DesignKit

/// Which agent's touches to show: "All", then each agent that did something in what is shown. As segments when they fit
/// the room left beside it, else as a menu, so it never sets how wide the panel must be: a narrow inspector keeps its
/// width.
@MainActor
final class AgentPicker: NSView {
    var onPick: (Int?) -> Void = { _ in }
    /// At the room's trailing edge (the panel's row) or its leading one (the Map tab's bar).
    var trailing = true
    private var agents: [Int] = []
    private var names: [String] = []
    private var segments = CapsuleSegments(labels: [])
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
        let chosen: NSView = agents.count <= 3 ? segments : popup
        return NSSize(width: chosen.fittingSize.width, height: Metrics.segment.height)
    }

    /// The agents present in `work` (in its places or steps), by their index.
    static func present(_ work: AgentWork) -> [Int] {
        Set(work.places.flatMap(\.agents) + work.steps.map(\.agent)).sorted()
    }

    func show(_ present: [Int], names allNames: [String], picked: Int?) {
        let names = present.map { allNames.indices.contains($0) ? allNames[$0] : "" }
        isHidden = present.count < 2
        if present != agents || names != self.names {
            agents = present
            self.names = names
            let labels = [String(localized: "All")] + names
            segments.removeFromSuperview()
            segments = CapsuleSegments(labels: labels, target: self, action: #selector(picked(_:)))
            segments.controlSize = .small
            addSubview(segments)
            popup.removeAllItems()
            popup.addItems(withTitles: [String(localized: "All Agents")] + names)
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
        let index = picked.flatMap { agents.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        segments.selectedSegment = index
        popup.selectItem(at: index)
    }

    /// Segments when all of them fit, else the popup; either at the trailing edge.
    override func layout() {
        super.layout()
        let wide = segments.fittingSize, narrow = popup.fittingSize
        let fits = agents.count <= 3 && wide.width <= bounds.width
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
        onPick(index <= 0 || index > agents.count ? nil : agents[index - 1])
    }
}
