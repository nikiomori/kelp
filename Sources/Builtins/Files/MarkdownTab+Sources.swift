import AppKit
import Core
import DesignKit
import KelpKit

/// Update on a dashboard whose canvas.json declares its sources (`DashboardSource`): Kelp runs their commands again
/// itself, without waking the agent, and writes each figure's new value and time into the boards. Each command runs
/// only once the user has allowed it, asked once a page (kept in UIState); 30 seconds each at most. A dashboard
/// without sources asks its agent as before.
extension MarkdownTab {
    func refreshSources() -> Bool {
        let sources = DashboardSource.read(editor.text)
        guard !sources.isEmpty else { return false }
        Task { await refresh(sources) }
        return true
    }

    private var allowedKey: String { "artifacts.sources:" + Artifacts.projectPath(url.path) }

    private func refresh(_ sources: [DashboardSource]) async {
        let allowed = Set(app.uiState[allowedKey]?.array?.compactMap(\.string) ?? [])
        let asked = sources.map(\.run).filter { !allowed.contains($0) }
        if !asked.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Run this dashboard’s commands?")
            alert.informativeText =
                String(localized: "Its agent wrote them to read its numbers. Kelp runs them on Update from now on:")
                + "\n\n" + asked.joined(separator: "\n")
            alert.addButton(withTitle: String(localized: "Allow and Update"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            app.uiState[allowedKey] = .array((allowed.union(asked)).sorted().map(JSONValue.string))
        }
        let root = Self.projectRoot(of: url.path), stamp = Date().formatted(date: .abbreviated, time: .shortened)
        var values: [(DashboardSource, String)] = [], failed: [String] = []
        for source in sources {
            let done = await Shell.run(app, source.run, cwd: root, timeout: 30)
            do {
                guard done.code == 0, let value = try source.value(done.stdout) else {
                    failed.append(source.name)
                    continue
                }
                values.append((source, value))
            } catch {
                failed.append(source.name)
            }
        }
        let folder = url.deletingLastPathComponent()
        for board in ArtifactCanvas.read(editor.text)?.boards.map(\.file) ?? [] {
            let path = folder.appendingPathComponent(board).path
            guard let file = await app.call(FilesRead(path: path)) else { continue }
            let next = values.reduce(file.text) { text, pair in
                BoardEdit.setFigures(text, from: pair.0.name, value: pair.1, note: pair.0.run + ", " + stamp)
            }
            if next != file.text { _ = await app.call(FilesWrite(path: path, text: next, base: file.stamp)) }
        }
        if !failed.isEmpty {
            Banner.show(
                String(localized: "Not updated: \(failed.joined(separator: ", ")) (its command failed)"), style: .error)
        }
    }
}
