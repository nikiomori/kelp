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
        let addons: LiveAddons = app.part { LiveAddons() }   // the one the panel on screen was built with
        return Contributions(
            panels: [
                PanelSpec(id: "addons", title: "Skills & MCP", icon: "powerplug", extensionId: "kelp.agents") {
                    let panel = AddonsPanel(app: app)
                    addons.panel = panel
                    return panel
                }
            ],
            commands: [
                CommandSpec(id: "agents.new", title: "New Agent", key: "opt+cmd+t") { args in
                    starter(app)?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string)
                },
                cmd("terminal.new", "New Terminal", "cmd+t") { starter(app)?.newTerminal() },
                cmd("terminal.tmux", "Attach to tmux Session…") { app.workbench.showTmuxSessions() },
                cmd("terminal.splitRight", "New Terminal to the Right", "cmd+d") {
                    app.workbench.splitTerminal(.right)
                },
                cmd("terminal.splitDown", "New Terminal Below", "shift+cmd+d") {
                    app.workbench.splitTerminal(.down)
                },
                cmd("agents.sideBySide", "Agents Side by Side", "ctrl+cmd+t") { app.workbench.toggleSideBySide() },
                cmd("agents.nextNeedingYou", "Show Agent Needing You", "shift+cmd+u") {
                    app.workbench.showNextNeedingAttention()
                },
                cmd("agents.usage", "Usage", "opt+cmd+u") { app.workbench.open("usage:") },
                cmd("agents.overview", "Agents Overview") { app.workbench.open("overview:") },
                cmd("agents.history", "Session History", "shift+cmd+h") { HistoryWindow.of(app).show() },
                // Works like Caffeine. While ticked, it keeps the Mac awake, and unticking it goes back to the
                // setting's default.
                cmd("power.keepAwake", "Keep Mac Awake") {
                    let always = app.settings[SettingKeys.keepAwake] == "always"
                    app.settings.set(SettingKeys.keepAwake, always ? nil : "always")
                }
            ] + addonsCommands(addons),
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
                    schemes: ["usage"],
                    make: {
                        HostedTabContent(
                            uri: $0, title: String(localized: "Usage"), icon: "chart.bar", app: app,
                            UsageReportView(app: app))
                    },
                    placeholder: { _ in (String(localized: "Usage"), .symbol("chart.bar"), nil) }),
                TabProvider(
                    schemes: ["overview"],
                    make: {
                        HostedTabContent(
                            uri: $0, title: String(localized: "Agents Overview"), icon: "rectangle.3.group", app: app,
                            OverviewView(app: app))
                    },
                    placeholder: { _ in (String(localized: "Agents Overview"), .symbol("rectangle.3.group"), nil) }),
                TabProvider(
                    schemes: ["subagent"], make: { SubagentTab(uri: $0, app: app) },
                    placeholder: { _ in (String(localized: "Subagent"), .symbol("list.bullet.rectangle"), nil) })
            ],
            // The plan limits show in the sidebar's foot, and each new reading is handled as it lands (for its pace and
            // its notifications). A note on the limits sits beside each agent wherever agents are chosen.
            sidebarSections: [
                SidebarSection(id: "limits", foot: true, title: "Plan Limits", shown: SettingKeys.readPlans) {
                    UsageFooter.make(app)
                }
            ],
            pushed: [{ LimitWatch.of(app).landed($0) }],
            plans: PlanNote.words(app),
            // Starts the strip over the Dock, which shows while Kelp is behind another app, and puts its items in the
            // Dock icon's menu. Also starts the context rings on agents' tabs, watched for the workspace on screen, and
            // the offer to continue the agents Kelp's going down cut short.
            launched: [{ AgentStrip.of(app).start() }, { ContextRings.start(app) }, { InterruptedAgents.start(app) }],
            dockMenu: [{ AgentStrip.of(app).dockItems($0) }],
            dockUsage: { LimitWatch.dockFace(app) },
            skills: [terminalsSkill, agentsSkill],
            quickSections: [OutputRows.section(app)]
        )
    }
}

// How the app keeps what the daemon pushes about agents' commands. These are the Agents built-in's own event kinds,
// not the shell's.
extension CommandsEvent: Pushed {
    package var key: String { session }
    package static var forgottenWith: WatchTopic? { .commands }
}

/// The Skills & MCP panel (built when first shown), for the commands that act on it. There is one per app, because
/// `contribute` runs again on every registry reload while the panel built first stays.
@MainActor
private final class LiveAddons { weak var panel: AddonsPanel? }

/// What the Skills & MCP panel's "+", ⋯ and right-click menus do, as commands on the panel on screen and its selected
/// row.
@MainActor private func addonsCommands(_ live: LiveAddons) -> [CommandSpec] {
    let shown: @MainActor () -> AddonsPanel? = { live.panel?.viewIfLoaded?.window == nil ? nil : live.panel }
    let chosen: @MainActor () -> Addon? = { shown()?.chosen }
    return [
        CommandSpec(id: "addons.add", title: "Skills & MCP: Add a Skill or MCP Server…", enabled: { shown() != nil }) {
            _ in shown()?.addAny()
        },
        CommandSpec(id: "addons.newSkill", title: "Skills & MCP: New Skill…", enabled: { shown() != nil }) { _ in
            shown()?.newSkill()
        },
        CommandSpec(
            id: "addons.restartChat", title: "Skills & MCP: Restart This Chat", enabled: { shown()?.shownChat != nil }
        ) { _ in
            shown()?.restart()
        },
        CommandSpec(id: "addons.open", title: "Skills & MCP: Open", enabled: { chosen()?.path != nil }) { _ in
            if let path = chosen()?.path { shown()?.open(path) }
        },
        CommandSpec(
            id: "addons.off", title: "Skills & MCP: Off in This Project",
            enabled: { chosen().map { $0.key != nil && !$0.off } ?? false }
        ) { _ in
            if let key = chosen()?.key { shown()?.flip([key], on: false) }
        },
        CommandSpec(
            id: "addons.on", title: "Skills & MCP: On in This Project",
            enabled: { chosen().map { $0.key != nil && $0.off } ?? false }
        ) { _ in
            if let key = chosen()?.key { shown()?.flip([key], on: true) }
        }
    ]
}

/// Returns what starts agents and terminals in the workspace on screen, and beeps when there is none.
@MainActor private func starter(_ app: AppModel) -> SessionStarter? {
    if app.workbench.starter == nil { NSSound.beep() }
    return app.workbench.starter
}
