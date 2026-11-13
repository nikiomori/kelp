import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// Tidy Up with Agent: the instruction files go to an agent in a new chat, with the `tidyInstructions` recipe (a
/// project's `.kelp.yaml` can change it). The agent checks what they name, then shortens, merges, moves or archives;
/// by default it reports first and waits for "apply". Kelp writes none of the files itself: the agent does, the one
/// whose memory it is.
@MainActor
struct TidyUp {
    let app: AppModel, worktreeId: String
    /// The instruction files listed: the sheet offers each one that has a file.
    let files: [Addon]

    /// `picked`: the file the person asked about; nil (the panel's ⋯): every file that needs a look, else all.
    func ask(picked: String? = nil) async {
        let files = files.filter { $0.path != nil }
        guard !files.isEmpty else { return }
        let looking = files.filter { $0.check?.needsLook == true }
        let ticked = picked.map { [$0] } ?? (looking.isEmpty ? files : looking).compactMap(\.path)
        let boxes = files.map { Self.box($0, on: ticked.contains($0.path ?? "")) }
        let mode = NSSegmentedControl(
            labels: [String(localized: "Show Me First"), String(localized: "Make Them Now")],
            trackingMode: .selectOne, target: nil, action: nil)
        mode.selectedSegment = 0
        let agents = app.catalog.installed(app.catalog.all).filter { $0.id != "shell" && $0.id != "custom" }
        let agent = NSPopUpButton()
        for a in agents { agent.addItem(withTitle: a.name) }
        agent.selectItem(at: agents.firstIndex { $0.id == app.catalog.defaultAgent } ?? 0)
        let weekly = NSButton(checkboxWithTitle: String(localized: "Repeat every week"), target: nil, action: nil)
        let alert = NSAlert()
        alert.messageText = String(localized: "Tidy Up Instructions")
        alert.informativeText = String(
            localized: """
                An agent checks every path, name and commit these files mention, then shortens, merges, moves or \
                archives what no longer holds. Memories aren’t deleted: they move to an archive folder agents don’t \
                load.
                """)
        alert.accessoryView = Self.stack(boxes + [mode, agent, weekly])
        alert.addButton(withTitle: String(localized: "Start"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await runSheet(alert) == .alertFirstButtonReturn, agents.indices.contains(agent.indexOfSelectedItem)
        else { return }
        let chosen = zip(files, boxes).filter { $0.1.state == .on }.compactMap(\.0.path)
        guard !chosen.isEmpty else { return }
        await start(
            chosen, apply: mode.selectedSegment == 1, agent: agents[agent.indexOfSelectedItem].id,
            weekly: weekly.state == .on)
    }

    private func start(_ paths: [String], apply: Bool, agent: String, weekly: Bool) async {
        let vars = [
            "instructionFiles": Self.described(paths), "mode": apply ? "apply" : "report",
            "backup": Paths.root.appendingPathComponent("tidy").path + "/<today, as YYYY-MM-DD>"
        ]
        guard let prompt = await app.call(RecipeRender(id: worktreeId, name: "tidyInstructions", vars: vars)) else {
            return
        }
        let title = String(localized: "Tidy Up")
        if weekly, let repo = app.worktree(worktreeId)?.repoId {
            _ = await app.call(
                RoutineSet(routine: Routine(name: title, repoId: repo, agent: agent, prompt: prompt, every: .weekly)))
        }
        let create = SessionCreate(worktreeId: worktreeId, agent: agent, prompt: prompt, title: title)
        guard let session = await app.call(create) else { return }
        app.upsert(session)
        app.workbench.open(TabURI.session(session.id))
    }

    /// The files as the agent is told them: Claude Code's memory index stands for its whole folder.
    nonisolated static func described(_ paths: [String]) -> String {
        paths.map { path in
            guard (path as NSString).lastPathComponent == "MEMORY.md" else { return path }
            let folder = (path as NSString).deletingLastPathComponent
            return "the Claude Code memory in \(folder)/ (MEMORY.md, its index, and the memory files beside it)"
        }.joined(separator: "; ")
    }

    private static func box(_ file: Addon, on: Bool) -> NSButton {
        let note = file.check.flatMap(AddonGroups.checkNote)?.text
        let title = [file.name, note].compactMap { $0 }.joined(separator: " — ")
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        box.toolTip = file.path
        return box
    }

    private static func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        stack.frame.size = stack.fittingSize
        return stack
    }
}
