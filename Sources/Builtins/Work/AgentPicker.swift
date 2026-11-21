import AppKit
import Core
import DesignKit

/// Which agent's touches to show: "All", then each agent that did something in what is shown. Two or three agents are
/// segments; more (a turn with many subagents) are a menu, which keeps its width.
@MainActor
final class AgentPicker: NSView {
    var onPick: (Int?) -> Void = { _ in }
    private var agents: [Int] = []
    private var names: [String] = []
    private var shown: NSView?

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
            shown?.removeFromSuperview()
            let labels = [String(localized: "All")] + names
            if present.count <= 3 {
                let segments = CapsuleSegments(labels: labels, target: self, action: #selector(picked(_:)))
                segments.controlSize = .small
                shown = segments
            } else {
                let menu = NSPopUpButton()
                menu.controlSize = .small
                menu.font = .ui(TextSize.caption)
                menu.addItems(withTitles: [String(localized: "All Agents")] + names)
                menu.target = self
                menu.action = #selector(picked(_:))
                shown = menu
            }
            shown.map { pin($0) }
        }
        let index = picked.flatMap { agents.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        (shown as? CapsuleSegments)?.selectedSegment = index
        (shown as? NSPopUpButton)?.selectItem(at: index)
    }

    @objc private func picked(_ sender: Any?) {
        let index =
            (sender as? CapsuleSegments)?.selectedSegment ?? (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0
        onPick(index <= 0 || index > agents.count ? nil : agents[index - 1])
    }
}
