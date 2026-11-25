import AppKit
import Core
import DesignKit
import KelpKit

/// Update on a dashboard whose canvas.json declares its sources (`DashboardSource`): Kelp runs their commands again
/// itself, without waking the agent, and writes each figure's new value and time into the boards. Each command runs
/// only once the user has allowed it, asked once a page (kept in UIState); 30 seconds each at most. A dashboard
/// without sources asks its agent as before. Once its commands are allowed, a dashboard also updates when it opens, and
/// while it is open every 15 minutes or every hour when the user picks that (also kept in UIState).
extension MarkdownTab {
    func refreshSources() -> Bool {
        let sources = DashboardSource.read(editor.text)
        guard !sources.isEmpty else { return false }
        Task { await refresh(sources) }
        return true
    }

    private var allowedKey: String { "artifacts.sources:" + Artifacts.projectPath(url.path) }
    private var everyKey: String { "artifacts.sourcesEvery:" + Artifacts.projectPath(url.path) }

    /// Minutes between updates while the dashboard is open, or nil: only when it opens and on Update.
    var updateEvery: Int? {
        get { app.uiState[everyKey]?.int }
        set {
            app.uiState[everyKey] = newValue.map(JSONValue.int)
            followSources()
        }
    }

    /// ⋯'s choice of how often a dashboard with sources updates while open; nil for any other page.
    func updateMenu() -> NSMenu? {
        guard isDashboard, !DashboardSource.read(editor.text).isEmpty else { return nil }
        let menu = NSMenu()
        for (minutes, title) in [
            (nil, String(localized: "When Opened")), (15, String(localized: "Every 15 Minutes")),
            (60, String(localized: "Every Hour"))
        ] as [(Int?, String)] {
            menu.add(title) { [weak self] in self?.updateEvery = minutes }.state = updateEvery == minutes ? .on : .off
        }
        return menu
    }

    /// The dashboard just opened: it updates now if its commands are all allowed, then on its schedule.
    func updateOnOpen() {
        Task { await refresh(DashboardSource.read(editor.text), onlyAllowed: true) }
        followSources()
    }

    /// The updates of open dashboards on their schedules, one each, stopped with the tab.
    private static let schedules = NSMapTable<MarkdownTab, Schedule>.weakToStrongObjects()
    private final class Schedule {
        let task: Task<Void, any Error>
        init(_ task: Task<Void, any Error>) { self.task = task }
        deinit { task.cancel() }
    }

    private func followSources() {
        Self.schedules.removeObject(forKey: self)
        guard let minutes = updateEvery, minutes > 0 else { return }
        let task = Task { [weak self] () throws in
            while true {
                try await Task.sleep(for: .seconds(minutes * 60))   // throws once cancelled, which ends it
                guard let self else { return }
                await refresh(DashboardSource.read(editor.text), onlyAllowed: true)
            }
        }
        Self.schedules.setObject(Schedule(task), forKey: self)
    }

    /// Runs the sources and writes their figures; `onlyAllowed` (opening, a timer) runs nothing until all are allowed.
    private func refresh(_ sources: [DashboardSource], onlyAllowed: Bool = false) async {
        let allowed = Set(app.uiState[allowedKey]?.array?.compactMap(\.string) ?? [])
        let asked = sources.map(\.run).filter { !allowed.contains($0) }
        if sources.isEmpty || onlyAllowed && !asked.isEmpty { return }
        if !asked.isEmpty {
            let why = String(
                localized: "Its agent wrote them to read its numbers. Kelp runs them on Update from now on.")
            let alert = NSAlert(
                question: String(localized: "Run this dashboard’s commands?"), detail: why,
                action: String(localized: "Allow and Update"))
            alert.accessoryView = NSScrollView.readOnly(asked.joined(separator: "\n"), lines: min(asked.count, 6))
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
            let names = failed.joined(separator: ", ")
            Banner.show(
                String(localized: "Not updated: \(names). Its command failed: ask the agent to fix it in canvas.json."),
                style: .error)
        }
    }
}
