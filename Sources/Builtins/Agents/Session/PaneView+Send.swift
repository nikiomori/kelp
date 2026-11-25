// A terminal's selection handed to an agent: a shell's build error, or one agent's output to another.
import AppKit
import DesignKit
import KelpKit

extension PaneView {
    /// Adds Send Selection to Agent, with its key, when there is a selection.
    func addSend(to menu: NSMenu, selection: String?) {
        guard selection?.isEmpty == false else { return }
        let send = menu.add(String(localized: "Send Selection to Agent")) { [weak self] in
            self?.sendSelectionToAgent()
        }
        app.extensions.showKey("editor.sendToAgent", on: send)
    }

    /// Types the selection into an agent's prompt without sending it: another agent's, never this session's own, which
    /// is the one the user was last with. Returns false when nothing is selected.
    @discardableResult func sendSelectionToAgent() -> Bool {
        guard let text = ghostty?.selection, !text.isEmpty else { return false }
        FileActions(app).sendToAgent(text: text, except: sessionId)
        return true
    }
}
