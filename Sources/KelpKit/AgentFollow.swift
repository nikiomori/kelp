import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Follow Edits: while it is on for an agent, each file the agent's tools change opens beside its tab, leaving the
/// keyboard where it is, in one tab that follows along. It is per agent, off until asked for, and forgotten when Kelp
/// quits. It works for agents whose hooks name the file (Claude Code's), and shows only while the agent's workspace is
/// on screen.
@MainActor
final class AgentFollow {
    private let app: AppModel
    private var following: [String: Watched] = [:]
    /// The file last shown for each agent. The agent's next file takes over its tab.
    private var shown: [String: String] = [:]

    static func of(_ app: AppModel) -> AgentFollow { app.part { AgentFollow(app) } }
    private init(_ app: AppModel) { self.app = app }

    /// Whether the agent's hooks report its edits.
    static func can(_ app: AppModel, _ sid: String) -> Bool {
        switch app.catalog.manifest(app.session(sid)?.agent)?.hooks {
        case .settingsFlag?, .settingsFile?: return true
        default: return false
        }
    }

    func follows(_ sid: String) -> Bool { following[sid] != nil }

    func toggle(_ sid: String) {
        if following.removeValue(forKey: sid) != nil {
            shown[sid] = nil
            return
        }
        let watched = Watched(.edits, in: app)
        watched.key = sid
        following[sid] = watched
        var seen: Int?   // the first count covers edits made before following started, so it isn't shown
        track(owner: watched) { [app] in
            app.latest(EditsEvent.self, sid)
        } changed: { [weak self] event in
            guard let event else { return }
            defer { seen = event.count }
            guard let path = event.path, let before = seen, event.count != before else { return }
            self?.show(path, of: sid)
        }
    }

    private func show(_ path: String, of sid: String) {
        guard let session = app.session(sid), session.worktreeId == app.workbench.workspaceId,
            let area = app.workbench.editors?.current
        else { return }
        let uri = TabURI.file(path)
        area.showBeside(uri, of: TabURI.session(sid), replacing: shown[sid])
        shown[sid] = uri
    }
}

extension EditsEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .edits }
}
