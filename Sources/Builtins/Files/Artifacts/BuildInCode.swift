import AppKit
import Core
import DesignKit
import KelpKit

/// Build in Code… (under Export in ⋯): the page, or one of a design's boards, handed to an agent to build as working
/// code (Open Design's Handoff, Claude Design → Claude Code). The sheet asks what, in which stack (guessed from the
/// project) and with which agent, then starts that agent with the brief: keep the look, the design system's tokens, the
/// pictures beside the page, and the decisions already made in the marks that are done.
extension MarkdownTab {
    func buildInCode() {
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Build in Code")
            alert.informativeText = String(
                localized: "An agent writes it as working code that keeps this look, and says how to run and check it.")
            let what = PointerPopUpButton(), stack = PointerPopUpButton(), agent = PointerPopUpButton()
            let boards = page == .canvas ? ArtifactCanvas.read(editor.text)?.boards ?? [] : []
            what.addItems(
                withTitles: boards.isEmpty ? [String(localized: "The Whole Page")] : boards.map { $0.title ?? $0.file })
            let root = Self.projectRoot(of: url.path)
            let stacks = Self.stacks, guessed = await guessStack(root: root)
            stack.addItems(withTitles: stacks)
            stack.selectItem(withTitle: guessed)
            let agents = app.catalog.installed.filter { Session.isAgent($0.id) }
            agent.addItems(withTitles: agents.map(\.name))
            let done = await doneMarks()
            let carry = NSTextField.label(
                String(localized: "With it: the page, the tokens, its pictures and the decided marks (\(done.count))"),
                font: .ui(TextSize.caption), color: .secondaryLabelColor)
            let grid = NSGridView(views: [
                [NSTextField.label(String(localized: "What"), font: .ui(TextSize.row)), what],
                [NSTextField.label(String(localized: "Stack"), font: .ui(TextSize.row)), stack],
                [NSTextField.label(String(localized: "Agent"), font: .ui(TextSize.row)), agent],
                [NSView(), carry]
            ])
            grid.rowSpacing = Metrics.gap
            grid.frame.size = NSSize(width: Metrics.alertAccessory, height: grid.fittingSize.height)
            alert.accessoryView = grid
            alert.addButton(withTitle: String(localized: "Start"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn else { return }
            let board = boards.indices.contains(what.indexOfSelectedItem) ? boards[what.indexOfSelectedItem].file : nil
            let brief = Self.brief(
                page: Artifacts.projectPath(url.path), board: board, stack: stack.titleOfSelectedItem ?? guessed,
                decided: done)
            let chosen = agents.indices.contains(agent.indexOfSelectedItem) ? agents[agent.indexOfSelectedItem].id : nil
            app.workbench.starter?.newAgent(chosen, prompt: brief)
        }
    }

    static let stacks = ["SwiftUI", "React", "Next.js", "Vue", "Svelte", "HTML and CSS"]

    /// The stack the project is in, from its manifest files (read through the daemon).
    private func guessStack(root: String) async -> String {
        if await app.quiet(FilesRead(path: root + "/Package.swift")) != nil { return "SwiftUI" }
        guard let text = await app.quiet(FilesRead(path: root + "/package.json"))?.text else { return "HTML and CSS" }
        return Self.stack(packageJSON: text)
    }

    /// The web stack a package.json names, the most particular first.
    static func stack(packageJSON text: String) -> String {
        for (key, stack) in [
            ("\"next\"", "Next.js"), ("\"svelte\"", "Svelte"), ("\"vue\"", "Vue"), ("\"react\"", "React")
        ]
        where text.contains(key) {
            return stack
        }
        return "HTML and CSS"
    }

    /// What the agent is asked.
    static func brief(page: String, board: String?, stack: String, decided: [String]) -> String {
        let folder = (page as NSString).deletingLastPathComponent
        let what = board.map { "\(folder)/\($0)" } ?? page
        var lines = [
            "Build \(what) in \(stack), in this project, where code like it belongs.",
            "Keep the look: the tokens are in .kelp/design/tokens.json, the pictures in \(folder).",
            "Write runnable code, not a mock-up, and say how to run it and how to check it matches."
        ]
        if !decided.isEmpty {
            lines.append("Decisions already made on the page: " + decided.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// The done marks' last notes, the decisions made on the page.
    func doneMarks() async -> [String] {
        let notes = url.deletingLastPathComponent().appendingPathComponent(ArtifactMarks.file).path
        guard let file = await app.quiet(FilesRead(path: notes)) else { return [] }
        return ArtifactMarks.read(Data(file.text.utf8)).marks.filter { $0.state == .done }.map {
            "#\($0.id) \($0.rounds.last?.note ?? "")"
        }
    }
}
