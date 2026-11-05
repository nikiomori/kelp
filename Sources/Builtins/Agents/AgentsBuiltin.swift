import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit
import KelpKit

extension Builtins {

    package static let agents = Builtin("kelp.agents", "Agents & Terminals", "Agent sessions and terminals as tabs.",
                                        icon: "sparkles", essential: true) { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["session"], make: { SessionTab(uri: $0, app: app) },
                              closeUnbuilt: { await SessionTab.close(app, session: TabURI.body($0)) },
                              menu: { SessionTab.menu(app, $0, uri: $1, workspace: $2, openBeside: $3) })]
        c.tabs.append(TabProvider(schemes: ["usage"]) { _ in UsageTab(app: app) })
        c.tabs.append(TabProvider(schemes: ["subagent"]) { SubagentTab(uri: $0, app: app) })
        c.settings = [
            SettingsSection(id: "agents", title: "Agents", icon: "sparkles", specs: [
                s("agents.default", "Default agent", "enum", "claude",
                  "Used by New Agent (⌥⌘T). More agents are in the Agent Catalog.", options: app.catalog.all.map(\.id)),
                s("agents.commandsBar", "Show the commands an agent runs", "boolean", false,
                  "A line under its terminal with the commands it ran.",
                  help: "A line under Claude Code's terminal with the shell commands it ran; a click lists them, and a click on one shows what it printed."),
                s("agents.editInKelp", "Edit agent prompts in Kelp", "boolean", true,
                  "⌃G opens an agent's prompt in a tab here.",
                  help: "⌃G in an agent opens its prompt in a tab here. For agents started from now on."),
                s("sessions.hibernateMinutes", "Pause idle agents", "number", 0, "Paused agents free memory and resume the same conversation.",
                  options: ["0", "15", "30", "60", "240"]),
                s("agents.updateIdle", "Update idle agents", "boolean", true,
                  "Restarts into an update after its turn, in the same conversation.",
                  help: "When Claude Code installs an update, an agent restarts into it once its turn is over, in the same conversation. Not while it asks you something, runs anything in the background, or has text in its prompt."),
                s("agents.recap", "Recap when you're away", "boolean", true,
                  "What it did and what's left, if it finishes while you're away.",
                  help: "A Claude Code agent that finishes while nobody's at the Mac says what it did and what's left, from a fork of its conversation that leaves the conversation as it was. Uses a little of its plan."),
                s("agents.childReports", "Report back to the parent agent", "boolean", true,
                  "The other agent's result or question comes back as input.",
                  help: "When an agent starts another with kelp, the other's result or question comes to it as input."),
                s("power.keepAwake", "Keep Mac awake", "enum", "agents", options: ["agents", "always", "off"]),
                s("usage.readPlans", "Show plan limits", "boolean", true,
                  "At the bottom of the sidebar, read without spending tokens.",
                  help: "How much of each agent's plan is used, at the bottom of the sidebar; read in the background, no tokens.", group: "Plan limits"),
                s("usage.limits", "Limits to show", "enum", "all", "At the bottom of the sidebar: the fullest limit, or a row for each agent.",
                  options: ["fullest", "all"], group: "Plan limits", requires: "usage.readPlans"),
                s("usage.resets", "Reset time beside a limit", "boolean", true, "Only when it resets within 12 hours.",
                  group: "Plan limits", requires: "usage.readPlans"),
                s("usage.pace", "Even pace mark", "boolean", true,
                  "A tick where an even pace would be by now.",
                  help: "A tick on the bar: how much would be used by now, spending evenly until the reset.",
                  group: "Plan limits", requires: "usage.readPlans"),
                s("usage.alertAt", "Warn about limits at", "enum", "80", "A notification at this level, and again at 95%.",
                  options: ["off", "70", "80", "90"], group: "Plan limits", requires: "usage.readPlans"),
                s("artifacts.where", "Where agents make pages", "enum", "agent",
                  "Docs, slides and designs; reviews stay in the project.",
                  help: "Docs, slides and designs: an agent with artifacts of its own (Claude Code on claude.ai) makes them there. Reviews stay in the project.",
                  options: ["agent", "local"]),
                // Under one heading, the help a line each: three "Skill:" titles and three-line help read as a wall.
                s("agents.skills.extensions", "Write Kelp extensions", "boolean", true,
                  "Ask Claude Code for a panel, tab or command: it knows how to make one.", group: "Claude Code skills"),
                s("agents.skills.settings", "Change Kelp settings", "boolean", true,
                  "Claude Code reads and changes these settings when you ask.", group: "Claude Code skills"),
                s("agents.skills.terminals", "Run commands in Kelp tabs", "boolean", true,
                  "Tests and servers run in a tab you can watch; Claude Code reads what they print.", group: "Claude Code skills"),
                s("agents.skills.agents", "Hand work to other agents", "boolean", true,
                  "Claude Code can start another agent with kelp and gets its result back.", group: "Claude Code skills"),
                s("agents.skills.artifacts", "Make docs and reviews", "boolean", true,
                  "Claude Code puts a doc, or choices for you to pick from, on a page beside it.", group: "Claude Code skills"),
                s("agents.skills.vm", "Run commands in Kelp machines", "boolean", true,
                  "Claude Code runs Linux builds, tests and servers in a machine of yours, not on this Mac.", group: "Claude Code skills"),
                s("agents.skills.browser", "Use pages in Kelp's browser", "enum", "auto",
                  "Your app in a tab beside it; a project can have its own.",
                  help: "Claude Code opens your app in a tab beside it and works in it while you watch. A project can have its own: right-click it.",
                  options: ["auto", "on", "off"], group: "Claude Code skills")
            ], custom: { AnyView(AccountsSettings(app: app)) }, keywords: ["Accounts"], order: 30),
            SettingsSection(id: "notifications", title: "Notifications", icon: "bell", specs: [
                s("agents.onWaiting", "When an agent needs you", "enum", "sound", "Comes at once, even while you type.",
                  options: ["off", "banner", "sound"]),
                s("agents.remindAfter", "Remind if an agent still waits", "enum", "10", "Once. Not after you opened it or muted its row.",
                  options: ["off", "5", "10", "30"], requires: "agents.onWaiting"),
                s("agents.onFinish", "When an agent finishes", "enum", "banner", "Turns shorter than the time below stay quiet.",
                  options: ["off", "banner", "sound"]),
                s("agents.quietUnder", "Stay quiet for turns under", "number", 20, "Finished agents only; the row shows them either way.",
                  options: ["0", "10", "20", "30", "60"], requires: "agents.onFinish"),
                s("agents.onError", "When an agent fails", "enum", "sound", options: ["off", "banner", "sound"]),
                s("agents.holdBanners", "Hold finished agents while I type", "boolean", true,
                  "They come as one when you stop; questions come at once.",
                  help: "A finished or failed agent's banner waits until you stop typing in Kelp for 20 seconds, then they come as one. Questions come at once."),
                s("agents.dockStrip", "Show agents above the Dock", "enum", "always", "With Kelp behind another app: see them work and answer from there.",
                  options: ["always", "needed", "off"], group: "Dock"),
                s("agents.dockStrip.comesFor", "Comes up for", "enum", "failures", "A row you muted stays quiet here too.",
                  options: ["questions", "failures", "all"], group: "Dock", requires: "agents.dockStrip=needed"),
                s("agents.dockStrip.fullScreen", "Over full-screen apps", "boolean", true, "Off: a film or a talk stays clear of it; a banner still tells you.",
                  group: "Dock", requires: "agents.dockStrip"),
                s("agents.dockIcon", "Dock icon", "enum", "icon", "What Kelp's icon in the Dock shows. Also in its menu, on a right-click.",
                  options: ["icon", "agents", "usage"], group: "Dock"),
                s("phone.url", "Phone notifications (ntfy address)", "string", "",
                  "When you've been away 5 minutes or Kelp is closed.",
                  help: "When an agent asks, fails or hits a limit and you've been away for 5 minutes or Kelp is closed. Anyone who knows this address can read what's sent.", group: "Phone", placeholder: "https://ntfy.sh/your-topic"),
                s("phone.details", "Show what the agent says on the phone", "boolean", false, "Off: the agent's and the workspace's names only.",
                  group: "Phone", requires: "phone.url")
            ], custom: { AnyView(TestNotificationRow(app: app)) }, order: 50),
            SettingsSection(id: "catalog", title: "Agent Catalog", icon: "square.grid.2x2", specs: [],
                            custom: { AnyView(AgentsSettings(app: app)) }, keywords: app.catalog.all.map(\.name), fillsPane: true, order: 40),
            SettingsSection(id: "terminal", title: "Terminal", icon: "terminal", specs: [
                s("terminal.fontFamily", "Font", "font", "", "Default: the theme's / Ghostty's font."),
                s("terminal.fontSize", "Font size", "number", 13, range: [8, 40]),
                s("terminal.cursorStyle", "Cursor style", "enum", "block", options: ["block", "bar", "underline"]),
                s("terminal.optionAsAlt", "Option key sends Alt (Meta)", "boolean", false),
                s("terminal.cleanCopy", "Copy text without borders", "boolean", true,
                  "Drops box borders and an agent's gutter, and rejoins lines it wrapped."),
                s("terminal.useGhosttyConfig", "Also read ~/.config/ghostty/config", "boolean", false,
                  "Keybindings and other Ghostty options; the theme's colors still apply."),
                s("terminal.tmux", "Run terminals inside tmux", "boolean", false,
                  "They keep running when Kelp quits or updates.",
                  help: "They keep running when Kelp quits or updates, on the host for a remote project. Closing the tab ends them. Needs tmux.")
            ], order: 60)
        ]
        c.commands = [
            CommandSpec(id: "agents.new", title: "New Agent", key: "opt+cmd+t") { args in
                editor(app)?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string)
            },
            cmd("terminal.new", "New Terminal", "cmd+t") { editor(app)?.newTerminal() },
            cmd("terminal.tmux", "Attach to tmux Session…") { app.quickOpen.showTmux() },
            cmd("terminal.splitRight", "Split Right", "cmd+d") { editor(app)?.splitFocused(.right) },
            cmd("terminal.splitDown", "Split Down", "shift+cmd+d") { editor(app)?.splitFocused(.down) },
            cmd("agents.sideBySide", "Agents Side by Side", "ctrl+cmd+t") { editor(app)?.toggleSideBySide() },
            cmd("agents.nextNeedingYou", "Show Agent Needing You", "shift+cmd+u") { app.workbench.showNextNeedingAttention() },
            cmd("agents.usage", "Usage", "opt+cmd+u") { app.workbench.open("usage:") },
            cmd("agents.history", "Session History", "shift+cmd+h") { app.historyWindow.show() },
            // Like Caffeine: ticked keeps the Mac awake until unticked, which goes back to the setting's default.
            cmd("power.keepAwake", "Keep Mac Awake") {
                app.settings.set("power.keepAwake", app.settings.string("power.keepAwake") == "always" ? nil : .string("always"))
            }
        ]
        return c
    }
}
