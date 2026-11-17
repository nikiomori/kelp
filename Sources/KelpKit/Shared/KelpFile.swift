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

    /// Whether the workspace's .kelp.yaml is trusted now, asking the user first if it isn't.
    func trusted(_ wid: String) async -> Bool {
        guard let info = await app.call(ScriptsList(worktreeId: wid)) else { return false }
        return await trusted(wid, info)
    }

    /// Trusts the file as `info` shows it, by the digest of the text shown, so a file changed since (by an agent or a
    /// pull) isn't trusted unseen.
    package func trusted(_ wid: String, _ info: ScriptsList.Result) async -> Bool {
        guard !info.trusted else { return true }
        // A snapshot run takes clicks and keys from its environment (DevAids), so anyone could start one that presses
        // Trust. That is why a snapshot window never trusts anything.
        guard !Self.snapshot, await askTrust(info) else { return false }
        return await app.call(ScriptsTrust(worktreeId: wid, digest: info.digest)) != nil
    }

    /// Asks every time before running in a folder that holds pull request `number`'s code, because the file's trust
    /// doesn't cover that code.
    private func runsOnPullRequest(_ number: Int, _ info: ScriptsList.Result) async -> Bool {
        guard !Self.snapshot else { return false }
        let alert = NSAlert(
            question: String(localized: "Run setup on pull request #\(number)?"),
            detail: String(
                localized:
                    "Its code comes from whoever wrote the pull request: what setup installs or builds can run their scripts as you. "
            ) + String(localized: "Skip it to read the code first."),
            action: String(localized: "Run Setup"), cancel: String(localized: "Skip"))
        alert.accessoryView = Self.trustText(info)
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    /// Runs one of the file's commands by name, once the file is trusted, and leaves showing the tab to the caller.
    /// When Run is there, Run runs it (ending an earlier copy, and keeping it as the workspace's run). Otherwise the
    /// command gets a session of its own.
    func run(_ wid: String, _ name: String) async -> Session? {
        if let runs = app.extensions.all.runs { return await runs.run(wid, name) }
        guard let session = await app.call(app.workbench.sized(ScriptsRun(worktreeId: wid, name: name))) else {
            return nil
        }
        app.upsert(session)
        return session
    }

    /// Runs a new workspace's setup when its .kelp.yaml has one. The setup waits for the file's trust (asked here
    /// first) and runs in a tab below, as Run shows a run.
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

    /// Asks the first time a project's commands would run. The question shows everything that trusting the file
    /// allows (commands, the agents and links a new workspace gets, the prompts it gives agents), and whose file it is.
    private func askTrust(_ info: ScriptsList.Result) async -> Bool {
        let file = (info.file as NSString).abbreviatingWithTildeInPath
        let detail =
            String(localized: "\(file) asks Kelp to run these as you, in this folder. ")
            + String(
                localized:
                    "Trust it only if you know where this project comes from. Kelp asks again if the file changes.")
        let alert = NSAlert(
            question: String(localized: "Run this project's commands?"), detail: detail,
            action: String(localized: "Trust and Run"))
        alert.accessoryView = Self.trustText(info)
        return await runSheet(alert) == .alertFirstButtonReturn
    }

    /// Shows the file's effects as the file spells them, scrollable when long.
    static func trustText(_ info: ScriptsList.Result) -> NSView {
        var lines: [String] = []
        if let setup = info.setup { lines.append("setup: \(setup)") }
        for script in info.scripts { lines.append("\(script.name): \(script.command)") }
        if !info.tabs.isEmpty { lines.append("tabs: " + info.tabs.joined(separator: ", ")) }
        if !info.shared.isEmpty { lines.append("shared: " + info.shared.joined(separator: ", ")) }
        if let command = info.issueCommand { lines.append("issueCommand: \(command)") }
        for (name, recipe) in info.recipes.sorted(by: { $0.key < $1.key }) { lines.append("recipe.\(name): \(recipe)") }
        return NSScrollView.readOnly(lines.joined(separator: "\n"), lines: lines.count, width: 360)
    }
}
