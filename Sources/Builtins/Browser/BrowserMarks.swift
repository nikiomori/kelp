// What the pages agents drive show outside their tabs (`AgentPages`): a mark on the agent's row, the tab's look, the
// agent's card, and a subagent's last step; and the choice on the project menu of whether new chats get the browser
// skill.
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

@MainActor
enum BrowserMarks {
    /// The browser mark on an agent's row: lit in the agent's colour for a while after it acted on a page, grey while
    /// the page is only open, in the accent colour while the user has the page; none without a page. A click brings the
    /// page up. Its subagents that acted on a page lately have their dots lit.
    static func row(_ row: SidebarItem.Kind, _ app: AppModel) -> [RowMark] {
        guard case .agent(let sid) = row else { return [] }
        let pages = AgentPages.of(app), own = pages.of(session: sid)
        guard let mark = pages.mark(for: sid), let first = own.first else { return [] }
        let lit = mark.holder == .agent ? mark.color : nil, title = first.page.title
        let tip: String
        switch mark.holder {
        case .user: tip = String(localized: "You have its page: \(title)")
        case .asked: tip = String(localized: "It asks you on its page: \(title)")
        case .agent where lit == nil: tip = String(localized: "Its page: \(title)")
        case .agent: tip = String(localized: "Working in its page: \(title)")
        }
        return [
            RowMark(
                .button, symbol: "safari", tint: mark.holder != .agent ? .themeAccent : lit ?? .secondaryLabelColor,
                glow: lit, tip: tip, lights: pages.litSubagents(of: sid), lightColor: first.page.color
            ) { pages.show(first.id) }
        ]
    }

    /// The page tabs of `workspace` an agent drives: whose, and the glow in its colour while it acts there.
    static func driven(_ workspace: String, _ app: AppModel) -> [String: (session: String, glow: NSColor?)] {
        let pages = AgentPages.of(app)
        let here = pages.pages.values.filter { $0.workspace == workspace }
        return Dictionary(here.map { ($0.tab, ($0.session, pages.glow(tab: $0.tab))) }) { first, _ in first }
    }

    /// In an agent's card: whether its chats get the browser skill, and the page it drives.
    static func card(_ session: Session, _ app: AppModel, close: @escaping @MainActor () -> Void) -> AnyView? {
        let skill = session.browser.map { "Browser \(BrowserSkillWords.line($0))" }
        guard skill != nil || !AgentPages.of(app).of(session: session.id).isEmpty else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                if let skill {
                    Text(skill).font(.ui(TextSize.caption)).foregroundStyle(.tertiary).lineLimit(1)
                }
                AgentPageCard(app: app, session: session.id, close: close)
            })
    }

    /// A subagent's last `kelp browser` command: what it did on its page, in words.
    static func step(_ session: String, _ subagent: String, _ command: String, _ app: AppModel) -> String? {
        let pages = AgentPages.of(app).of(session: session)
        guard command.contains("kelp browser"), let done = pages.first(where: { $0.page.subagent == subagent })?.page
        else { return nil }
        guard let done = done.steps.last else { return nil }
        return String(localized: "Browser · \(done.text)")
    }

    /// Whether new chats in a project get Kelp's browser skill: as Settings say (the daemon says why, a moment after
    /// the menu opens), or always or never in this project.
    static func menu(_ row: SidebarItem.Kind, _ menu: NSMenu, _ app: AppModel) {
        guard case .project(let id) = row, let worktree = app.gitFolder(project: id),
            RemoteHost.of(worktree.path) == nil
        else { return }
        let key = BrowserSkill.choiceKey(id), own = app.uiState[key]?.string.flatMap(BrowserSkill.Choice.init)
        let list = NSMenu()
        list.add(String(localized: "Automatic")) { app.uiState[key] = nil }.state = own == nil ? .on : .off
        for (choice, title) in [(BrowserSkill.Choice.on, String(localized: "On")), (.off, String(localized: "Off"))] {
            list.add(title) { app.uiState[key] = .string(choice.rawValue) }.state = own == choice ? .on : .off
        }
        list.addItem(.separator())
        let why = list.addItem(
            withTitle: String(localized: "For new chats in this project"), action: nil, keyEquivalent: "")
        why.isEnabled = false
        Task {
            guard let skill = await app.quiet(SkillsBrowser(worktreeId: worktree.id)) else { return }
            why.title = String(localized: "New chats: browser \(BrowserSkillWords.line(skill.line))")
        }
        menu.add(String(localized: "Browser for Agents"), submenu: list)
        menu.addItem(.separator())
    }
}

/// Whether a chat gets the browser skill and why ("on · Vite in package.json", `BrowserSkill.line`), in the app's
/// language: a reason in its words, the web app found as it is.
enum BrowserSkillWords {
    static func line(_ daemonLine: String) -> String {
        guard let skill = BrowserSkill.parse(daemonLine) else { return daemonLine }
        return (skill.on ? String(localized: "on") : String(localized: "off")) + " · "
            + (skill.reason.map(words) ?? skill.why)
    }

    static func words(_ reason: BrowserSkill.Reason) -> String {
        switch reason {
        case .project: String(localized: "set for this project")
        case .always: String(localized: "Always, in Settings")
        case .never: String(localized: "Never, in Settings")
        case .used: String(localized: "an agent used it here")
        case .localPage: String(localized: "a local page is open here")
        case .noWebApp: String(localized: "no web app found")
        }
    }
}
