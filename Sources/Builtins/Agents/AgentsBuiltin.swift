import Agents
import AppKit
import Core
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {

    package static let agents = Builtin(
        "kelp.agents", "Agents & Terminals", "Agent sessions and terminals as tabs.",
        icon: "sparkles", essential: true
    ) { app in
        var contributions = Contributions()
        contributions.tabs = [
            TabProvider(
                schemes: ["session"], make: { SessionTab(uri: $0, app: app) },
                closeUnbuilt: { await SessionTab.close(app, session: TabURI.body($0)) },
                menu: { SessionTab.menu(app, $0, uri: $1, workspace: $2, openBeside: $3) })
        ]
        contributions.tabs.append(TabProvider(schemes: ["usage"]) { _ in UsageTab(app: app) })
        contributions.tabs.append(TabProvider(schemes: ["subagent"]) { SubagentTab(uri: $0, app: app) })
        contributions.settings = [
            SettingsSection(
                id: "agents", title: "Agents", icon: "sparkles",
                specs: [
                    s(SettingKeys.defaultAgent, "Default agent", "enum",
                        "Used by New Agent (⌥⌘T). More agents are in the Agent Catalog.",
                        options: app.catalog.all.map(\.id)),
                    s(SettingKeys.commandsBar, "Show the commands an agent runs", "boolean",
                        "A line under its terminal with the commands it ran.",
                        help:
                            "A line under Claude Code's terminal with the shell commands it ran; a click lists them, and a click on one shows what it printed."
                    ),
                    s(SettingKeys.editInKelp, "Edit agent prompts in Kelp", "boolean",
                        "⌃G opens an agent's prompt in a tab here.",
                        help: "⌃G in an agent opens its prompt in a tab here. For agents started from now on."),
                    s(SettingKeys.hibernateMinutes, "Pause idle agents", "number",
                        "Paused agents free memory and resume the same conversation.",
                        options: ["0", "15", "30", "60", "240"],
                        labels: labels(["0", "15", "30", "60", "240"], pauseAfter)),
                    s(SettingKeys.updateIdle, "Update idle agents", "boolean",
                        "Restarts into an update after its turn, in the same conversation.",
                        help:
                            "When Claude Code installs an update, an agent restarts into it once its turn is over, in the same conversation. Not while it asks you something, runs anything in the background, or has text in its prompt."
                    ),
                    s(SettingKeys.recap, "Recap when you're away", "boolean",
                        "What it did and what's left, if it finishes while you're away.",
                        help:
                            "A Claude Code agent that finishes while nobody's at the Mac says what it did and what's left, from a fork of its conversation that leaves the conversation as it was. Uses a little of its plan."
                    ),
                    s(SettingKeys.childReports, "Report back to the parent agent", "boolean",
                        "The other agent's result or question comes back as input.",
                        help:
                            "When an agent starts another with kelp, the other's result or question comes to it as input."
                    ),
                    s(SettingKeys.keepAwake, "Keep Mac awake", "enum", options: ["agents", "always", "off"],
                        labels: [
                            "agents": String(localized: "While Agents Work"), "always": String(localized: "Always"),
                            "off": String(localized: "Never")
                        ], look: "segments"),
                    s(SettingKeys.readPlans, "Show plan limits", "boolean",
                        "At the bottom of the sidebar, read without spending tokens.",
                        help:
                            "How much of each agent's plan is used, at the bottom of the sidebar; read in the background, no tokens.",
                        group: "Plan limits"),
                    s(SettingKeys.usageLimits, "Limits to show", "enum",
                        "At the bottom of the sidebar: the fullest limit, or a row for each agent.",
                        options: ["fullest", "all"],
                        labels: ["fullest": String(localized: "Fullest Limit"), "all": String(localized: "All Agents")],
                        look: "segments", group: "Plan limits", requires: "usage.readPlans"),
                    s(SettingKeys.usageResets, "Reset time beside a limit", "boolean",
                        "Only when it resets within 12 hours.",
                        group: "Plan limits", requires: "usage.readPlans"),
                    s(SettingKeys.usagePace, "Even pace mark", "boolean",
                        "A tick where an even pace would be by now.",
                        help: "A tick on the bar: how much would be used by now, spending evenly until the reset.",
                        group: "Plan limits", requires: "usage.readPlans"),
                    s(SettingKeys.alertAt, "Warn about limits at", "enum",
                        "A notification at this level, and again at 95%.",
                        options: ["off", "70", "80", "90"],
                        labels: labels(["off", "70", "80", "90"]) { $0 == "off" ? String(localized: "Off") : "\($0)%" },
                        group: "Plan limits", requires: "usage.readPlans"),
                    s(SettingKeys.artifactsWhere, "Where agents make pages", "enum",
                        "Docs, slides and designs; reviews stay in the project.",
                        help:
                            "Docs, slides and designs: an agent with artifacts of its own (Claude Code on claude.ai) makes them there. Reviews stay in the project.",
                        options: ["agent", "local"],
                        labels: [
                            "agent": String(localized: "Agent’s Own When It Has One"),
                            "local": String(localized: "Always on This Mac")
                        ]),
                    // Under one heading, the help a line each: three "Skill:" titles and three-line help read as a wall.
                    s(SettingKeys.skillExtensions, "Write Kelp extensions", "boolean",
                        "Ask Claude Code for a panel, tab or command: it knows how to make one.",
                        group: "Claude Code skills"),
                    s(SettingKeys.skillSettings, "Change Kelp settings", "boolean",
                        "Claude Code reads and changes these settings when you ask.", group: "Claude Code skills"),
                    s(SettingKeys.skillTerminals, "Run commands in Kelp tabs", "boolean",
                        "Tests and servers run in a tab you can watch; Claude Code reads what they print.",
                        group: "Claude Code skills"),
                    s(SettingKeys.skillAgents, "Hand work to other agents", "boolean",
                        "Claude Code can start another agent with kelp and gets its result back.",
                        group: "Claude Code skills"),
                    s(SettingKeys.skillArtifacts, "Make docs and reviews", "boolean",
                        "Claude Code puts a doc, or choices for you to pick from, on a page beside it.",
                        group: "Claude Code skills"),
                    s(SettingKeys.skillVM, "Run commands in Kelp machines", "boolean",
                        "Claude Code runs Linux builds, tests and servers in a machine of yours, not on this Mac.",
                        group: "Claude Code skills"),
                    s(SettingKeys.skillDatabases, "Query the project's databases", "boolean",
                        "Claude Code reads your databases through Kelp, never their passwords; a change waits for "
                            + "your Allow.",
                        group: "Claude Code skills"),
                    s(SettingKeys.skillBrowser, "Use pages in Kelp's browser", "enum",
                        "Your app in a tab beside it; a project can have its own.",
                        help:
                            "Claude Code opens your app in a tab beside it and works in it while you watch. A project can have its own: right-click it.",
                        options: ["auto", "on", "off"],
                        labels: [
                            "auto": String(localized: "In Web Projects"), "on": String(localized: "Always"),
                            "off": String(localized: "Never")
                        ], group: "Claude Code skills")
                ], custom: { AnyView(AccountsSettings(app: app)) }, keywords: ["Accounts"], order: 30,
                previews: ["Plan limits": { AnyView(LimitsSample()) }]),
            SettingsSection(
                id: "notifications", title: "Notifications", icon: "bell",
                specs: [
                    s(SettingKeys.onWaiting, "When an agent needs you", "enum",
                        "Comes at once, even while you type.",
                        options: ["off", "banner", "sound"], labels: alerts, look: "segments"),
                    s(SettingKeys.remindAfter, "Remind if an agent still waits", "enum",
                        "Once. Not after you opened it or muted its row.",
                        options: ["off", "5", "10", "30"],
                        labels: labels(["off", "5", "10", "30"]) {
                            $0 == "off" ? String(localized: "Off") : String(localized: "After \($0) Minutes")
                        }, requires: "agents.onWaiting"),
                    s(SettingKeys.onFinish, "When an agent finishes", "enum",
                        "Turns shorter than the time below stay quiet.",
                        options: ["off", "banner", "sound"], labels: alerts, look: "segments"),
                    s(SettingKeys.quietUnder, "Stay quiet for turns under", "number",
                        "Finished agents only; the row shows them either way.",
                        options: ["0", "10", "20", "30", "60"],
                        labels: labels(["0", "10", "20", "30", "60"]) {
                            $0 == "0" ? String(localized: "Off") : String(localized: "\($0) Seconds")
                        }, requires: "agents.onFinish"),
                    s(SettingKeys.onError, "When an agent fails", "enum", options: ["off", "banner", "sound"],
                        labels: alerts, look: "segments"),
                    s(SettingKeys.holdBanners, "Hold finished agents while I type", "boolean",
                        "They come as one when you stop; questions come at once.",
                        help:
                            "A finished or failed agent's banner waits until you stop typing in Kelp for 20 seconds, then they come as one. Questions come at once."
                    ),
                    s(SettingKeys.dockStrip, "Show agents above the Dock", "enum",
                        "With Kelp behind another app: see them work and answer from there.",
                        options: ["always", "needed", "off"],
                        labels: [
                            "needed": String(localized: "When Needed"), "always": String(localized: "Always"),
                            "off": String(localized: "Never")
                        ], look: "pictures", group: "Dock"),
                    s(SettingKeys.dockStripComesFor, "Comes up for", "enum",
                        "A row you muted stays quiet here too.",
                        options: ["questions", "failures", "all"],
                        labels: [
                            "questions": String(localized: "Questions"),
                            "failures": String(localized: "Questions and Failures"),
                            "all": String(localized: "Anything New")
                        ], group: "Dock", requires: "agents.dockStrip=needed"),
                    s(SettingKeys.dockStripFullScreen, "Over full-screen apps", "boolean",
                        "Off: a film or a talk stays clear of it; a banner still tells you.",
                        group: "Dock", requires: "agents.dockStrip"),
                    s(SettingKeys.dockIcon, "Dock icon", "enum",
                        "What Kelp's icon in the Dock shows. Also in its menu, on a right-click.",
                        options: ["icon", "agents", "usage"],
                        labels: [
                            "agents": String(localized: "Agents"), "usage": String(localized: "Plan Usage"),
                            "icon": String(localized: "App Icon")
                        ], look: "pictures", group: "Dock"),
                    s(SettingKeys.phoneURL, "Phone notifications (ntfy address)", "string",
                        "When you've been away 5 minutes or Kelp is closed.",
                        help:
                            "When an agent asks, fails or hits a limit and you've been away for 5 minutes or Kelp is closed. Anyone who knows this address can read what's sent.",
                        group: "Phone", placeholder: "https://ntfy.sh/your-topic"),
                    s(SettingKeys.phoneDetails, "Show what the agent says on the phone", "boolean",
                        "Off: the agent's and the workspace's names only.",
                        group: "Phone", requires: "phone.url")
                ], custom: { AnyView(TestNotificationRow(app: app)) }, order: 50,
                pictures: [SettingKeys.dockStrip.key: { AnyView(DockStripPicture(option: $0)) }]),
            SettingsSection(
                id: "catalog", title: "Agent Catalog", icon: "square.grid.2x2", specs: [],
                custom: { AnyView(AgentsSettings(app: app)) }, keywords: app.catalog.all.map(\.name), fillsPane: true,
                order: 40),
            SettingsSection(
                id: "terminal", title: "Terminal", icon: "terminal",
                specs: [
                    s(SettingKeys.terminalFontFamily, "Font", "font", "Default: the theme's / Ghostty's font."),
                    s(SettingKeys.terminalFontSize, "Font size", "number", range: [8, 40]),
                    s(SettingKeys.cursorStyle, "Cursor style", "enum", options: ["block", "bar", "underline"],
                        look: "pictures"),
                    s(SettingKeys.optionAsAlt, "Option key sends Alt (Meta)", "boolean"),
                    s(SettingKeys.cleanCopy, "Copy text without borders", "boolean",
                        "Drops box borders and an agent's gutter, and rejoins lines it wrapped."),
                    s(SettingKeys.useGhosttyConfig, "Also read ~/.config/ghostty/config", "boolean",
                        "Keybindings and other Ghostty options; the theme's colors still apply."),
                    s(SettingKeys.tmux, "Run terminals inside tmux", "boolean",
                        "They keep running when Kelp quits or updates.",
                        help:
                            "They keep running when Kelp quits or updates, on the host for a remote project. Closing the tab ends them. Needs tmux."
                    )
                ], order: 60)
        ]
        // The plan limits: the sidebar's foot, each reading as it lands (their pace, their notifications), and the note
        // beside each agent where agents are chosen.
        contributions.sidebarSections = [SidebarSection(id: "limits", foot: true) { UsageFooter.make(app) }]
        contributions.pushed = [{ LimitWatch.of(app).landed($0) }]
        contributions.planNotes = { UsageView.notes(app) }
        contributions.dockUsage = { LimitWatch.dockFace(app) }
        // The strip over the Dock, with Kelp behind another app, and its items in the Dock icon's menu.
        contributions.launched = [{ AgentStrip.of(app).start() }]
        contributions.dockMenu = [{ AgentStrip.of(app).dockItems($0) }]
        contributions.commands = [
            CommandSpec(id: "agents.new", title: "New Agent", key: "opt+cmd+t") { args in
                editor(app)?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string)
            },
            cmd("terminal.new", "New Terminal", "cmd+t") { editor(app)?.newTerminal() },
            cmd("terminal.tmux", "Attach to tmux Session…") { app.quickOpen.showTmux() },
            cmd("terminal.splitRight", "Split Right", "cmd+d") { editor(app)?.splitFocused(.right) },
            cmd("terminal.splitDown", "Split Down", "shift+cmd+d") { editor(app)?.splitFocused(.down) },
            cmd("agents.sideBySide", "Agents Side by Side", "ctrl+cmd+t") { editor(app)?.toggleSideBySide() },
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
        ]
        return contributions
    }
}

/// Settings only this built-in reads (the rest are `SettingKeys` in Core).
extension SettingKeys {
    static let commandsBar = Setting("agents.commandsBar", false)
    static let usageResets = Setting("usage.resets", true)
    static let usagePace = Setting("usage.pace", true)
    static let dockStripFullScreen = Setting("agents.dockStrip.fullScreen", true)
}

/// Each option's name, by `name`.
private func labels(_ options: [String], _ name: (String) -> String) -> [String: String] {
    Dictionary(uniqueKeysWithValues: options.map { ($0, name($0)) })
}

/// How a notification comes, for each kind of news.
private let alerts = [
    "sound": String(localized: "Banner + Sound"), "banner": String(localized: "Banner"), "off": String(localized: "Off")
]

/// "After 4 Hours": when an idle agent pauses.
private func pauseAfter(_ value: String) -> String {
    let minutes = Int(value) ?? -1
    return minutes == 0
        ? String(localized: "Never")
        : minutes == 60
            ? String(localized: "After 1 Hour")
            : minutes > 0 && minutes % 60 == 0
                ? String(localized: "After \(minutes / 60) Hours") : String(localized: "After \(value) Minutes")
}
