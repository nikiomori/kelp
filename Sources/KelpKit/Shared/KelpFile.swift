import AppKit
import Core
import DesignKit
import WorkbenchKit

/// A workspace's .kelp.yaml as the shell runs it. The file is trusted first, by asking the user the first time
/// something would run (Run's commands, a layout template that runs them, a new workspace's setup). A command is run by
/// name through Run when Run is there, else as a plain session, so with Run turned off a template and a new workspace's
/// setup still run what the file says.
@MainActor
package struct KelpFile {
    let app: AppModel
    package init(app: AppModel) { self.app = app }

    /// Whether the workspace's .kelp.yaml is trusted now, asked first if it isn't.
    func trusted(_ wid: String) async -> Bool {
        guard let info = await app.call(ScriptsList(worktreeId: wid)) else { return false }
        return await trusted(wid, info)
    }

    /// Trusted as `info` shows it: the digest of the text shown, so a file changed since (an agent, a pull) isn't
    /// trusted unseen.
    package func trusted(_ wid: String, _ info: ScriptsList.Result) async -> Bool {
        guard !info.trusted else { return true }
        // A snapshot run takes clicks and keys from its environment (DevAids): anyone could start one that presses
        // Trust, so that window never trusts anything.
        guard !Self.snapshot, await askTrust(info) else { return false }
        return await app.call(ScriptsTrust(worktreeId: wid, digest: info.digest)) != nil
    }

    /// The folder holds pull request `number`'s code, which the file's trust doesn't cover: asked every time.
    private func runsOnPullRequest(_ number: Int, _ info: ScriptsList.Result) async -> Bool {
        guard !Self.snapshot else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Run setup on pull request #\(number)?")
        alert.informativeText =
            String(
                localized:
                    "Its code comes from whoever wrote the pull request: what setup installs or builds can run their scripts as you. "
            )
            + String(localized: "Skip it to read the code first.")
        alert.accessoryView = Self.trustText(info)
        alert.addButton(withTitle: String(localized: "Run Setup"))
        alert.addButton(withTitle: String(localized: "Skip"))
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    /// A command of the file by name, its trust asked already, its tab left to the caller: Run's run when Run is there
    /// (an earlier copy ended, kept as the workspace's run), else a session of its own.
    func run(_ wid: String, _ name: String) async -> Session? {
        if let runs = app.extensions.all.runs { return await runs.run(wid, name) }
        guard let session = await app.call(app.workbench.sized(ScriptsRun(worktreeId: wid, name: name))) else {
            return nil
        }
        app.upsert(session)
        return session
    }

    /// A new workspace's setup, when its .kelp.yaml has one that waits for the file's trust (asked here first): in a
    /// tab below, as Run shows a run.
    package func setup(_ wid: String, pullRequest: Int?) async {
        guard let info = await app.quiet(ScriptsList(worktreeId: wid)), info.setup != nil else { return }
        if let pullRequest { guard await runsOnPullRequest(pullRequest, info) else { return } }
        guard await trusted(wid, info), let session = await run(wid, "setup"), !app.workbench.isHidden(session.id)
        else { return }
        if wid == app.workbench.workspaceId {
            app.workbench.open(TabURI.session(session.id), split: .down, workspace: wid, focus: false)
        } else {
            app.workbench.openInBackground(TabURI.session(session.id), workspace: wid)
        }
    }

    private static var snapshot: Bool { ProcessInfo.processInfo.environment["KELP_SNAPSHOT"] != nil }

    /// The first time a project's commands would run: everything trusting the file allows (commands, the agents and links
    /// a new workspace gets, the prompts it puts in agents' mouths), and whose it is.
    private func askTrust(_ info: ScriptsList.Result) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Run this project's commands?")
        alert.informativeText =
            String(
                localized:
                    "\((info.file as NSString).abbreviatingWithTildeInPath) asks Kelp to run these as you, in this folder. "
            )
            + String(
                localized:
                    "Trust it only if you know where this project comes from. Kelp asks again if the file changes.")
        alert.accessoryView = Self.trustText(info)
        alert.addButton(withTitle: String(localized: "Trust and Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    /// The file's effects as the file spells them, scrollable when long.
    static func trustText(_ info: ScriptsList.Result) -> NSView {
        var lines: [String] = []
        if let setup = info.setup { lines.append("setup: \(setup)") }
        for script in info.scripts { lines.append("\(script.name): \(script.command)") }
        if !info.tabs.isEmpty { lines.append("tabs: " + info.tabs.joined(separator: ", ")) }
        if !info.shared.isEmpty { lines.append("shared: " + info.shared.joined(separator: ", ")) }
        if let command = info.issueCommand { lines.append("issueCommand: \(command)") }
        for (name, recipe) in info.recipes.sorted(by: { $0.key < $1.key }) { lines.append("recipe.\(name): \(recipe)") }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: min(220, CGFloat(max(lines.count, 1)) * 16 + 8))
        scroll.drawsBackground = false
        if let text = scroll.documentView as? NSTextView {
            text.string = lines.joined(separator: "\n")
            text.isEditable = false
            text.drawsBackground = false
            text.font = .uiMono(TextSize.caption)
        }
        return scroll
    }
}
