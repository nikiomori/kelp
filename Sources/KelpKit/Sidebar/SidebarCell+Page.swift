// An agent's row: the page it drives (`AgentPages`), as a mark beside its ring.
import AppKit
import DesignKit

extension SidebarCell {
    /// The browser mark: lit in the agent's colour for a while after it acted on a page, grey while the page is only open,
    /// in the accent colour while the user has the page; none without a page. A click brings the page up.
    static func pageButton(_ cell: SidebarCell) -> PointerButton {
        let button = PointerButton(image: .symbol("safari")) { [weak cell] in
            guard let cell, case .agent(let sid) = cell.node.kind else { return }
            if let id = cell.app.agentPages.of(session: sid).first?.id { cell.app.agentPages.show(id) }
        }
        button.radius = nil
        button.symbolConfiguration = .chrome(Metrics.iconSmall)
        button.wantsLayer = true
        button.layer?.shadowOffset = .zero
        button.layer?.shadowRadius = Metrics.iconGlow / 2
        button.isHidden = true
        return button
    }

    func showPage(_ sid: String) {
        let mark = app.agentPages.mark(for: sid), pages = app.agentPages
        page.isHidden = mark == nil
        family.browsing = pages.litSubagents(of: sid)
        family.browsingColor = pages.of(session: sid).first?.page.color ?? .systemPurple
        guard let mark else { return }
        let lit = mark.holder == .agent ? mark.color : nil
        page.contentTintColor = mark.holder != .agent ? .themeAccent : lit ?? .secondaryLabelColor
        page.layer?.shadowColor = lit?.cgColor
        page.layer?.animate("shadowOpacity", to: Float(lit == nil ? 0 : 0.9), duration: Motion.fast, timing: .easeOut)
        let title = pages.of(session: sid).first?.page.title ?? ""
        let words: String
        switch mark.holder {
        case .user: words = String(localized: "You have its page: \(title)")
        case .asked: words = String(localized: "It asks you on its page: \(title)")
        case .agent where lit == nil: words = String(localized: "Its page: \(title)")
        case .agent: words = String(localized: "Working in its page: \(title)")
        }
        page.toolTip = words
        page.setAccessibilityLabel(page.toolTip)
    }
}

extension SidebarController {
    /// The pages agents drive: the browser mark on their rows, lit while they act (`AgentPages`).
    func followAgentPages() {
        track(owner: self, now: false) { [app] in
            app.agentPages.pages.values.map { "\($0.session) \($0.subagent ?? "") \($0.holder) \($0.title)" }.sorted()
                + app.agentPages.lit.sorted()
        } changed: { [weak self] _ in
            self?.updateVisibleCells()
        }
    }
}
