import Agents
import AppKit
import Core
import DesignKit
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    package static let agents = Builtin(
        "kelp.agents", "Agents & Terminals", "Agent sessions and terminals as tabs.",
        icon: "sparkles", essential: true
    ) { app in
        return Contributions(
            commands: [
                CommandSpec(id: "agents.new", title: "New Agent", key: "opt+cmd+t") { args in
                    starter(app)?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string)
                },
                cmd("terminal.new", "New Terminal", "cmd+t") { starter(app)?.newTerminal() },
                cmd("terminal.tmux", "Attach to tmux Session…") { app.workbench.showTmuxSessions() },
                cmd("terminal.splitRight", "Split Right", "cmd+d") { app.workbench.split(.right) },
                cmd("terminal.splitDown", "Split Down", "shift+cmd+d") { app.workbench.split(.down) },
                cmd("agents.sideBySide", "Agents Side by Side", "ctrl+cmd+t") { app.workbench.toggleSideBySide() },
                cmd("agents.nextNeedingYou", "Show Agent Needing You", "shift+cmd+u") {
                    app.workbench.showNextNeedingAttention()
                },
                cmd("agents.usage", "Usage", "opt+cmd+u") { app.workbench.open("usage:") },
                cmd("agents.history", "Session History", "shift+cmd+h") { HistoryWindow.of(app).show() },
                // Like Caffeine: ticked keeps the Mac awake until unticked, which goes back to the setting's default.
                cmd("power.keepAwake", "Keep Mac Awake") {
                    let always = app.settings[SettingKeys.keepAwake] == "always"
                    app.settings.set(SettingKeys.keepAwake, always ? nil : "always")
                }
            ],
            settings: agentsSettings(app),
            tabs: [
                TabProvider(
                    schemes: ["session"], make: { SessionTab(uri: $0, app: app) },
                    placeholder: { uri in
                        let session = app.session(TabURI.body(uri))
                        let title = session.map(app.catalog.displayName) ?? String(localized: "Session")
                        return (title, app.catalog.icon(session?.agent), title)
                    },
                    badge: { uri in
                        let sid = TabURI.body(uri)
                        return .of(app.session(sid), meter: app.latest(ContextEvent.self, sid)?.shown)
                    },
                    releasable: true,
                    closeUnbuilt: { await SessionTab.close(app, session: TabURI.body($0)) },
                    menu: { SessionTab.menu(app, $0, uri: $1, workspace: $2, openBeside: $3) }),
                TabProvider(
                    schemes: ["usage"], make: { _ in UsageTab(app: app) },
                    placeholder: { _ in (String(localized: "Usage"), .symbol("chart.bar"), nil) }),
                TabProvider(
                    schemes: ["subagent"], make: { SubagentTab(uri: $0, app: app) },
                    placeholder: { _ in (String(localized: "Subagent"), .symbol("list.bullet.rectangle"), nil) })
            ],
            // The plan limits: the sidebar's foot, each reading as it lands (their pace, their notifications), and the note
            // beside each agent where agents are chosen.
            sidebarSections: [SidebarSection(id: "limits", foot: true) { UsageFooter.make(app) }],
            pushed: [{ LimitWatch.of(app).landed($0) }],
            plans: PlanNote.words(app),
            // The strip over the Dock, with Kelp behind another app, and its items in the Dock icon's menu.
            launched: [{ AgentStrip.of(app).start() }],
            dockMenu: [{ AgentStrip.of(app).dockItems($0) }],
            dockUsage: { LimitWatch.dockFace(app) },
            skills: [terminalsSkill, agentsSkill]
        )
    }
}

// How the app keeps what the daemon pushes about agents' commands: Agents' own kinds, not the shell's.
extension CommandsEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .commands }
}

/// What starts agents and terminals in the workspace on screen; a beep when there is none.
@MainActor private func starter(_ app: AppModel) -> SessionStarter? {
    if app.workbench.starter == nil { NSSound.beep() }
    return app.workbench.starter
}
