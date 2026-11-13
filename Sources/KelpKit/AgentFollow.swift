import Agents
import AppKit
import Core
import DesignKit
import WorkbenchKit

/// Follow Edits: while it's on for an agent, each file its tools change opens beside its tab, the keys left where they
/// are, one tab following along. Per agent, off until asked, forgotten when Kelp quits. Agents whose hooks name the
/// file (Claude Code's); shown only while the agent's workspace is on screen.
@MainActor
final class AgentFollow {
    private let app: AppModel
    private var following: [String: Watched] = [:]
    /// The file last shown for each agent: the next one takes its tab.
    private var shown: [String: String] = [:]

    static func of(_ app: AppModel) -> AgentFollow { app.part { AgentFollow(app) } }
    private init(_ app: AppModel) { self.app = app }

    /// Whether the agent's hooks tell its edits.
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
        var seen: Int?   // the first count is what it changed before: not shown
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
