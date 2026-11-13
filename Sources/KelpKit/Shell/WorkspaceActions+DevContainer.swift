import AppKit
import Core
import DesignKit

extension WorkspaceActions {
    /// Run in Dev Container, a check item: from then on the project's new terminals and agents start in its dev
    /// container (the daemon's `DevContainer`), when its folder has one. This Mac's projects only.
    func addDevContainer(to menu: NSMenu, _ repo: Repo) {
        guard RemoteHost.of(repo.path) == nil else { return }
        let app = self.app, on = app.uiState.strings(Repo.devContainerKey)
        let note = String(localized: "\(repo.name)'s new terminals and agents start in its dev container.")
        let token = String(localized: "Claude Code there signs in with CLAUDE_CODE_OAUTH_TOKEN in Settings › Agents.")
        let item = menu.add(String(localized: "Run in Dev Container")) {
            let now = on.contains(repo.id) ? on.filter { $0 != repo.id } : on + [repo.id]
            Task {
                guard await app.uiState.save(Repo.devContainerKey, .array(now.map(JSONValue.string))) else { return }
                guard now.contains(repo.id) else { return }
                Banner.show(note + " " + token)
            }
        }
        item.state = on.contains(repo.id) ? .on : .off
    }
}
