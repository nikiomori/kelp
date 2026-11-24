import AgentData
import Core
import Foundation

extension Sessions {
    /// Called when a turn of `session` ends. Each page the session made in its workspace keeps a version of how the
    /// turn left it, named by the turn's prompt. A remote project's folder here holds only its marker, so its artifacts
    /// list is read again wherever it shows instead. That read asks the host for the pages the turn published
    /// (`pickUpHostArtifacts`).
    func keepArtifactVersions(session: String, worktree: String?, prompt: String) {
        Log.store.attempt("keeping the versions of \(session)'s artifacts") {
            guard let workspace = try store.worktree(worktree ?? "") else { return }
            if remotes.of(workspace.path) != nil {
                watches.touched(.init(topic: .artifacts, key: workspace.id), tag: UUID().uuidString)
                return
            }
            guard FileManager.default.fileExists(atPath: Artifacts.dir(root: workspace.path).path) else { return }
            try Artifacts.keepVersions(root: workspace.path, session: session, label: prompt)
            try Artifacts.settleMarks(root: workspace.path, session: session, prompt: prompt)
        }
    }

    /// Picks up the pages a remote project's Claude Code published, since no hook of Kelp's runs on the host. It reads
    /// what the session's conversation on the host says, over the connection already open, from the second after the
    /// session's last kept page onward. The pages are kept in the project's folder here, which the panel lists. Only
    /// the list's own read calls this, one at a time (`Watches`), because two runs at once would both find a new page
    /// new.
    func pickUpHostArtifacts(of session: Session, in root: String) throws {
        guard let remote = remotes.of(root) else { return }
        let since = Artifacts.list(root: root).filter { $0.record.session == session.id }
            .map { $0.record.updated ?? $0.record.created }.max()
        guard
            let data = agentUsage.conversations.remoteConversation(
                of: session, on: remote, read: Artifacts.hostPublishes(since: since))
        else { return }
        for page in Artifacts.published(inTranscript: data) {
            let sent = page.page?.file == nil ? page.page : nil   // a sent file is on the host, so no copy is kept
            _ = try Artifacts.addNative(
                url: page.url, title: page.title, type: page.type, root: root, session: session.id, page: sent,
                now: page.at ?? Date())
        }
    }
}

extension ArtifactNew: Handled {
    static let agents = AgentAccess.acts
    static var quick: Bool { true }
    var fence: Fence { Fence(writesInFolder: cwd) }   // the folder of the workspace whose panel shows the page
    func handle(_ store: Store) throws -> String {
        let root = try artifactsRoot(store, cwd: cwd, session: session)
        return try Artifacts.create(kind, title: title, root: root, session: session).path
    }
}

extension ArtifactAdd: Handled {
    static let agents = AgentAccess.acts
    /// An agent's hook waits for this call to answer.
    static var quick: Bool { true }
    var fence: Fence { Fence(writesInFolder: cwd) }
    func handle(_ store: Store) throws -> Bool {
        guard url.hasPrefix("https://") else { throw RPCError.invalidParams("a page's link starts with https://") }
        let root = try artifactsRoot(store, cwd: cwd, session: session)
        return try Artifacts.addNative(url: url, title: title, type: type, root: root, session: session, page: page)
            != nil
    }
}

/// Returns the folder whose artifacts a command run in `cwd` means. That is the workspace that holds `cwd`, preferring
/// `session`'s own workspace as `IDE.workspace` picks. Otherwise it is `cwd` itself, as for a chat outside any project.
private func artifactsRoot(_ store: Store, cwd: String, session: String?) throws -> String {
    var isFolder: ObjCBool = false
    guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue
    else { throw RPCError.invalidParams("not a folder: \(cwd)") }
    let own = try session.flatMap { try store.session($0) }?.worktreeId
    return IDE.workspace(cwd: cwd, among: try store.worktrees().filter { !$0.archived }, own: own)?.path ?? cwd
}

/// Sends the check to the window, which draws the canvas again and answers with `ui.browser.reply`. This handler waits
/// for that answer.
extension ArtifactCheck: AsyncHandled {
    static let agents = AgentAccess.reads
    func handle(_ ui: UIStore) async throws -> [String] {
        guard path.hasPrefix("/"), path.hasSuffix("/" + Artifacts.Kind.design.file) else {
            throw RPCError.invalidParams("not a design's canvas.json: \(path)")
        }
        let clients = ui.clients, apps = clients.apps
        guard !apps.isEmpty else { throw RPCError.internalError("The Kelp app isn't running") }
        let request = UUID().uuidString, path = Paths.real(path) ?? path
        let answer = try await clients.reply(to: request, from: apps, within: Self.wait) {
            clients.notify(ArtifactCheckEvent(request: request, path: path), to: apps)
        }
        return answer.array?.compactMap(\.string) ?? []
    }
}

extension ArtifactCost: Handled {
    /// Returns what was spent on the page, from a little before it was made (because the turn read its guide first) to
    /// its last change.
    func handle(_: NoService) throws -> Spent? {
        guard let marker = path.range(of: "/\(Artifacts.folder)/") else { return nil }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent(), root = String(path[..<marker.lowerBound])
        guard let record = Artifacts.record(in: folder), let session = record.session,
            let transcript = ClaudeHistory.transcript(id: session)
        else { return nil }
        let changed =
            record.file == Artifacts.Kind.design.file
            ? Artifacts.canvasTime(path, root: root)
            : Artifacts.fileStat(path).map { Double($0.mtime.tv_sec) }
        let spent = ClaudeUsage.spent(
            transcript: transcript, from: record.created.timeIntervalSince1970 - 120,
            to: (changed ?? Date().timeIntervalSince1970) + 5)
        guard spent.calls > 0 else { return nil }
        return Spent(
            calls: spent.calls, output: spent.tokens.output,
            read: spent.tokens.input + spent.tokens.cacheRead + spent.tokens.cacheWrite, cost: spent.cost)
    }
}

extension Methods {
    static let artifactMethods: [any Answered.Type] = [
        ArtifactNew.self, ArtifactAdd.self, ArtifactCheck.self, ArtifactCost.self, ArtifactMarksChange.self,
        ArtifactKeepVersion.self, ArtifactKeepRestored.self, ArtifactReply.self, ArtifactAsk.self, ArtifactSuggest.self
    ]
}
