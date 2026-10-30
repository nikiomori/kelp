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
        c.settings = [
            SettingsSection(id: "agents", title: "Agents", icon: "sparkles", specs: [
                s("agents.default", "Default agent", "enum", "claude",
                  "Used by New Agent (⌥⌘T). More agents are in the Agent Catalog.", options: app.catalog.all.map(\.id)),
                // Under one heading, the help a line each: three "Skill:" titles and three-line help read as a wall.
                s("agents.skills.extensions", "Write Kelp extensions", "boolean", true,
                  "Ask Claude Code for a panel, tab or command: it knows how to make one.", group: "Claude Code skills"),
                s("agents.skills.settings", "Change Kelp settings", "boolean", true,
                  "Claude Code reads and changes these settings when you ask.", group: "Claude Code skills"),
                s("agents.skills.terminals", "Run commands in Kelp tabs", "boolean", true,
                  "Tests and servers run in a tab you can watch; Claude Code reads what they print.", group: "Claude Code skills"),
                s("agents.commandsBar", "Show the commands an agent runs", "boolean", false,
                  "A line under Claude Code's terminal with the shell commands it ran; a click lists them, and a click on one shows what it printed."),
                s("sessions.hibernateMinutes", "Pause idle agents", "number", 0, "Paused agents free memory and resume the same conversation.",
                  options: ["0", "15", "30", "60", "240"]),
                s("agents.updateIdle", "Update idle agents", "boolean", true,
                  "When Claude Code installs an update, an agent restarts into it once its turn is over, in the same conversation. Not while it asks you something, runs anything in the background, or has text in its prompt."),
                s("power.keepAwake", "Keep Mac awake", "enum", "agents", options: ["agents", "always", "off"]),
                s("usage.readPlans", "Show plan limits", "boolean", true,
                  "How much of each agent's plan is used, at the bottom of the sidebar; read in the background, no tokens."),
                s("agents.holdBanners", "Hold finished agents while I type", "boolean", true,
                  "A finished or failed agent's banner waits until you stop typing in Kelp for 20 seconds, then they come as one. Questions come at once.",
                  group: "Notifications"),
                s("agents.onFinish", "When an agent finishes", "enum", "banner", "Turns shorter than the time below stay quiet.",
                  options: ["sound", "banner", "off"], group: "Notifications"),
                s("agents.onWaiting", "When an agent needs you", "enum", "sound", "Comes at once, even while you type.",
                  options: ["sound", "banner", "off"], group: "Notifications"),
                s("agents.onError", "When an agent fails", "enum", "sound", options: ["sound", "banner", "off"], group: "Notifications"),
                s("agents.quietUnder", "Stay quiet for turns under", "number", 20, "Finished agents only; the row shows them either way.",
                  options: ["0", "10", "20", "30", "60"], group: "Notifications"),
                s("usage.alertAt", "Warn about limits at (%)", "enum", "80", "A notification when a plan limit reaches this, and again at 95. “off”: none.",
                  options: ["off", "70", "80", "90"], group: "Notifications")
            ], custom: { AnyView(VStack(alignment: .leading, spacing: 16) { CatalogLink(app: app); AccountsSettings(app: app) }) }),
            SettingsSection(id: "catalog", title: "Agent Catalog", icon: "square.grid.2x2", specs: [],
                            custom: { AnyView(AgentsSettings(app: app).frame(height: 460)) }),
            SettingsSection(id: "terminal", title: "Terminal", icon: "terminal", specs: [
                s("terminal.fontFamily", "Font", "font", "", "Default: the theme's / Ghostty's font."),
                s("terminal.fontSize", "Font size", "number", 13),
                s("terminal.cursorStyle", "Cursor", "enum", "block", options: ["block", "bar", "underline"]),
                s("terminal.optionAsAlt", "Option key sends Alt (Meta)", "boolean", false),
                s("terminal.cleanCopy", "Copy text without the TUI around it", "boolean", true,
                  "Drops box borders, an agent's indented gutter and trailing spaces from what you copy, and joins the lines an agent wrapped at the edge (a long command copies as one line)."),
                s("terminal.useGhosttyConfig", "Also read ~/.config/ghostty/config", "boolean", false,
                  "Keybindings and other Ghostty options; the theme's colors still apply."),
                s("terminal.tmux", "Run terminals inside tmux", "boolean", false,
                  "New terminals run in a tmux session of their own (on the host, for a remote project): it keeps running when Kelp quits or "
                    + "updates, and the tab attaches to it again; after a dropped SSH connection, Restart does. Closing the tab ends the session. "
                    + "Needs tmux; without it here, terminals are plain shells.")
            ])
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
