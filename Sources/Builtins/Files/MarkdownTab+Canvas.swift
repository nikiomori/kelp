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

    /// A message from Kelp's scripts on the canvas; false for one that isn't theirs.
    func canvasMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        switch kind {
        case "check": canvasChecked(body["issues"] as? [String] ?? [])
        case "marks": send(CanvasMark.message(marks(body), canvas: Artifacts.projectPath(url.path)), keep: [])
        case "marksDraft": keep(marks(body))
        case "pick":
            let row = (body["row"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            send(
                "Picked “\(row)” on \(Artifacts.projectPath(url.path)): build it out in full; take the other rows off "
                    + "canvas.json, keeping their files.", keep: nil)
        case "tweak":
            guard let board = body["board"] as? String, let name = body["name"] as? String,
                let value = body["value"] as? String
            else { return true }
            setTweak(board: board, name: name, value: value)
        default: return false
        }
        return true
    }

    var canvasLabels: CanvasEdit.Labels {
        let who = pageAuthor.map { app.catalog.name($0.agent) } ?? String(localized: "the Agent")
        return CanvasEdit.Labels(
            send: String(localized: "Send to \(who)"),
            pick: String(localized: "Pick"), tweaks: String(localized: "Tweaks"),
            note: String(localized: "What should change?"), remove: String(localized: "Remove"))
    }

    /// Mark in the bar: a click on a board puts a mark on it.
    func toggleMarking() {
        marking.toggle()
        runJS("kelpMark(\(marking))")
    }

    private func marks(_ body: [String: Any]) -> [CanvasMark] {
        (body["marks"] as? [[String: Any]] ?? []).compactMap { m in
            guard let board = m["board"] as? String, let target = m["target"] as? String else { return nil }
            return CanvasMark(
                board: board, target: target, text: m["text"] as? String ?? "", note: m["note"] as? String ?? "")
        }
    }

    private var notesPath: String { url.deletingLastPathComponent().appendingPathComponent(CanvasMark.file).path }

    /// The marks not sent yet, kept beside the canvas.
    private func keep(_ marks: [CanvasMark]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let text: String
        do { text = String(decoding: try encoder.encode(marks), as: UTF8.self) } catch { return }
        Task { await app.call(FilesWrite(path: notesPath, text: text, base: nil)) }
    }

    /// `line` to the chat that made the canvas (else the agent on screen); `keep`: the marks left after it.
    private func send(_ line: String, keep marks: [CanvasMark]?) {
        if let marks { keep(marks) }
        guard let author = pageAuthor else { return FileActions(app).sendToAgent(text: line) }
        Task { await app.call(SessionSend(id: author.id, text: line, enter: true)) }
    }

    /// A tweak moved on the canvas: its line in the board's file says the new value (unless the board changed since).
    private func setTweak(board: String, name: String, value: String) {
        let path = url.deletingLastPathComponent().appendingPathComponent(board).path
        Task {
            guard let file = await app.call(FilesRead(path: path)),
                let text = Tweak.set(name, to: value, in: file.text)
            else { return }
            await app.call(FilesWrite(path: path, text: text, base: file.stamp))
        }
    }

    /// An older version of the canvas made the files again: each of its boards, then the canvas.
    func restoreCanvas(_ snapshot: CanvasSnapshot) {
        let folder = url.deletingLastPathComponent()
        Task {
            for (board, text) in snapshot.boards.sorted(by: { $0.key < $1.key }) {
                guard
                    await app.call(FilesWrite(path: folder.appendingPathComponent(board).path, text: text, base: nil))
                        != nil
                else { return }
            }
            editor.apply(text: snapshot.canvas, selection: NSRange(location: 0, length: 0))
            _ = await saveFile?()
        }
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
