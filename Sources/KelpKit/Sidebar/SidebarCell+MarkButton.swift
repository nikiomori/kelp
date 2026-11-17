// A built-in's button on an agent's row, beside its dots (`RowMark`, `.button`): for example, the page the agent
// drives.
import AppKit
import DesignKit

extension SidebarCell {
    /// The button a built-in's mark shows as: its symbol in its tint, glowing in its glow; hidden without one. A click
    /// does what the mark says (brings the page up).
    static func markButton(_ cell: SidebarCell) -> PointerButton {
        let button = PointerButton(image: .symbol("safari")) { [weak cell] in cell?.buttonMark?.open?() }
        button.radius = nil
        button.symbolConfiguration = .chrome(Metrics.iconSmall)
        button.wantsLayer = true
        button.layer?.shadowOffset = .zero
        button.layer?.shadowRadius = Metrics.iconGlow / 2
        button.isHidden = true
        return button
    }

    /// The first button mark built-ins have for the agent, and the subagents' dots its marks light.
    func showMarkButton(_ sid: String) {
        let marks = app.extensions.rowMarks(.agent(sid)), mark = marks.first { $0.place == .button }
        family.browsing = marks.reduce(into: Set()) { $0.formUnion($1.lights) }
        family.browsingColor = marks.lazy.compactMap(\.lightColor).first ?? .systemPurple
        let shown = buttonMark?.symbol
        buttonMark = mark
        markButton.isHidden = mark == nil
        guard let mark else { return }
        if let symbol = mark.symbol, symbol != shown { markButton.image = .symbol(symbol) }
        markButton.contentTintColor = mark.tint ?? .secondaryLabelColor
        markButton.layer?.shadowColor = mark.glow?.cgColor
        markButton.layer?.animate(
            "shadowOpacity", to: Float(mark.glow == nil ? 0 : 0.9), duration: Motion.fast, timing: .easeOut)
        markButton.toolTip = mark.tip
        markButton.setAccessibilityLabel(mark.tip)
    }
}
