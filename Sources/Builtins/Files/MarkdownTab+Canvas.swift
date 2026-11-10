import AppKit
import Core
import DesignKit
import KelpKit

/// A design's canvas in its tab: drawn again whenever a board or the design system changes on disk, checked each time
/// it's drawn, and the check handed to `kelp artifact check` when one waits for it.
extension MarkdownTab {
    /// The project a page in `.kelp/artifacts` belongs to: the folder that holds `.kelp`.
    nonisolated static func projectRoot(of path: String) -> String {
        path.range(of: "/\(Artifacts.folder)/").map { String(path[..<$0.lowerBound]) } ?? path
    }

    /// Follows the checks `kelp artifact check` asks for. Its boards and the design system are followed by the bar: a
    /// change to them moves the canvas's time in the artifacts' list (`boardsChanged`).
    func followCanvas() {
        let path = Paths.real(url.path) ?? url.path
        track(owner: self) { [app] in
            app.latest(ArtifactCheckEvent.self, path)
        } changed: { [weak self] event in
            guard let self, let event else { return }
            pendingCheck = event.request
            rerender()   // drawn again from the files as they are now, then answered
        }
    }

    /// A board or the design system changed on disk: drawn again.
    func boardsChanged() { rerender(after: .milliseconds(150)) }

    /// What Kelp's script found on the canvas just drawn: shown in the bar, and the answer to a waiting check.
    func canvasChecked(_ issues: [String]) {
        checkIssues = issues
        onCheck?(issues)
        guard let request = pendingCheck else { return }
        pendingCheck = nil
        Task { await app.quiet(UIBrowserReply(request: request, result: .array(issues.map(JSONValue.string)))) }
    }

    /// The check's findings to the chat that made the canvas (else the agent on screen), to fix.
    func sendCheck() {
        guard let issues = checkIssues, !issues.isEmpty else { return }
        let line =
            "Fix on \(Artifacts.projectPath(url.path)) (kelp artifact check): "
            + issues.joined(separator: "; ")
        guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
        Task { await app.call(SessionSend(id: author.id, text: line, enter: true)) }
    }
}

extension ArtifactCheckEvent: Pushed {
    package var key: String { path }
    package static var forgottenWith: WatchTopic? { nil }
}
