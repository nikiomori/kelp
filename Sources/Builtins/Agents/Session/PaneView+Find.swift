// Find in an agent's terminal: Edit › Find through the responder chain, the find bar and its matches.
import AppKit
import Core
import DesignKit
import KelpKit
import TerminalKit

extension PaneView {
    // MARK: find (Edit › Find reaches the pane through the responder chain)
    @objc func performFindPanelAction(_ sender: Any?) {
        guard let terminal = ghostty else { return }
        switch NSFindPanelAction(rawValue: UInt((sender as? NSMenuItem)?.tag ?? 1)) {
        case .next?: terminal.perform(action: "navigate_search:next")
        case .previous?: terminal.perform(action: "navigate_search:previous")
        // Ghostty answers with start_search and the text
        case .setFindString?: terminal.perform(action: "search_selection")
        default: showFind(nil)
        }
    }

    func showFind(_ needle: String?) {
        guard let terminal = ghostty else { return }
        let bar =
            findBar
            ?? {
                let card = FindCard()
                card.onSearch = { terminal.perform(action: "search:" + $0) }
                card.onStep = { terminal.perform(action: "navigate_search:" + ($0 ? "next" : "previous")) }
                card.onClose = { [weak self] in
                    terminal.perform(action: "end_search")
                    self?.focus()
                }
                card.float(in: self, top: terminal, inset: NSSize(width: 14, height: 8))
                findBar = card
                return card
            }()
        bar.begin(needle)
    }

    func searchEvent(_ event: GhosttyTerminalView.SearchEvent) {
        switch event {
        case .started(let needle): showFind(needle)
        case .ended: findBar?.isHidden = true
        case .total(let count): findBar?.total = count
        case .selected(let count): findBar?.selected = count
        }
    }
}
