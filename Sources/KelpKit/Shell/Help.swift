import Core
import Foundation

/// Help › How Kelp Works: a short guide, opened as a Markdown tab. It is in the user's language, and its keys are read
/// from the bindings (`keyText`), so a rebound key reads as it works.
@MainActor
package enum Help {
    static func guide(_ keys: ExtensionRegistry) -> String {
        // A command's key as the menus show it, or "no key" once it was unbound.
        func k(_ id: String) -> String { keys.keyText(id) ?? String(localized: "no key") }
        return [projects(k), sidebar(k), middle(k), inspector(k), shortcuts(keys)].joined(separator: "\n\n")
    }

    private static func projects(_ k: (String) -> String) -> String {
        String(
            localized: """
                # How Kelp works

                ## Projects, workspaces, agents
                - **Project** — a folder, usually a git repository (the folder button over the sidebar, or File › Add \
                Project…, \(k("workspace.addProject"))). It’s a section in the sidebar.
                - **Workspace** — a screen of its own in that folder: its tabs, splits and agents. **+** next to the \
                project (New Chat, \(k("workspace.new"))) opens one at once; it’s named after the first thing you ask \
                an agent. Rename with a double-click; close with \(k("workspace.close")) (agents stop, files stay). \
                Several workspaces can work in the same folder.
                - **Agent** — Claude Code, Grok, Antigravity, Qwen… whatever is installed and runs on this Mac (found \
                automatically).
                """)
    }

    /// The marks, as `StatusMark` draws them, with `AgentStatus.words` for the states that have a word.
    private static func sidebar(_ k: (String) -> String) -> String {
        String(
            localized: """
                ## What the sidebar tells you
                One line per agent: its icon, name, how long ago its state changed, and a mark. The mark is the same \
                wherever the chat shows: its row, its tab, Quick Open and the switcher.

                | Mark | Means |
                | --- | --- |
                | a turning arc | Working: it’s thinking |
                | a pie filling up | Working, and it says how far it got |
                | a slow pulse | Working: it compacts its conversation |
                | a slow ring of eight dots | its turn is over, and it waits for a command it started |
                | a ring of dashes | the state was read off its screen, so it’s a guess |
                | an orange ring with a dot, the tab glowing | Needs your input: it asked you something (hover for the \
                question) |
                | an outlined check, a bold name | Done, and you haven’t looked yet |
                | a clock | stopped at its plan limit |
                | a red circle with an exclamation mark | Failed |
                | a circle with a cross | Ended |
                | a moon | Paused to save memory — opens where it left off |
                | none | Ready for a task |

                The row above the projects counts the chats that need you; a click goes to the next one, as \
                \(k("agents.nextNeedingYou")) does from anywhere (also in the Dock icon’s menu). Beside it are the \
                chats at work, at a limit and done; rest the pointer on a count to see its chats. A folded project or \
                group shows the logos of the chats that are at work or wait for you, each with its mark in a corner.

                **Limits** at the bottom: a ring per agent — how full its fullest limit is (orange from 70 %, red from \
                90 %), read from the agents' own /usage (Claude Code, Grok, Antigravity, Kimi, Copilot, Cursor) and \
                Codex’s logs. Hover or click for every limit and when it resets. Settings › Agents › Show plan limits \
                turns it off.
                """)
    }

    private static func middle(_ k: (String) -> String) -> String {
        let panes = ["view.paneLeft", "view.paneRight", "view.paneAbove", "view.paneBelow"].map(k).joined(
            separator: " ")
        return String(
            localized: """
                ## The middle: tabs and splits
                The **+** at the end of a pane’s tabs opens an agent, a terminal, a browser or what extensions add; the \
                agent’s icon before it starts the default agent (Settings › Agents) in one click. \
                \(k("terminal.splitRight")) splits right, \(k("terminal.splitDown")) down; drag a tab to an edge to \
                split, between groups to move it. Dividers stay where you drag them (View › Equalize Panes evens them \
                out); \(panes) move to the pane on that side. \(k("view.maximizePane")) lets the focused pane fill the \
                area and brings the others back. Agents open side by side, each in a pane of its own (four make a 2×2 \
                grid); terminals and files share one more pane. The button right of the search \
                (\(k("agents.sideBySide")); right-click hides it) shows them as tabs in one pane instead, and back; \
                splitting or dragging a tab to another pane arranges the panes by hand from then on.
                \(k("editor.closeTab")) closes a tab (in an empty workspace, the workspace); \(k("editor.reopenTab")) \
                brings it back in its place, an agent with its conversation, and File › Recently Closed lists the \
                rest. Edited files show a dot on their tab and in the window’s close button; \(k("editor.save")) saves.

                In a terminal ⌘F finds text in its scrollback (⌘G / ⇧⌘G next / previous, ⌘E the selection). \
                Right-click for copy, paste and splits. Drop files to type their paths; ⌘K clears, \
                \(k("view.biggerText")) / \(k("view.smallerText")) change the text size.
                """)
    }

    private static func inspector(_ k: (String) -> String) -> String {
        String(
            localized: """
                ## The inspector
                Files, Source Control — changes, staging, commit, history graph; click a file for its diff — Issues & \
                Pull Requests, and panels from extensions. ⌥⌘1–9 show a panel by its icon’s place in the row and put \
                the keys in its list: ↑ ↓ move, Return does what a click does, Esc goes back to the tab.

                ## Extensions and agents
                Everything above is an extension; turn them off in Settings › Extensions. To add one, ask Claude Code \
                in a tab: *"make a Kelp panel that lists my Docker containers"*. It knows how through Kelp’s \
                **skills** (Settings › Agents), which also let it change settings for you: *"switch Kelp to the \
                Dracula theme"*.

                ## Settings
                Kelp › Settings… (\(k("workbench.openSettings"))) — or ~/.kelp/settings.json, or \
                `kelp settings set <key> <value>` from any terminal.

                ## Adding projects
                File › Add Project… (\(k("workspace.addProject"))), or drop a folder on the sidebar or on Kelp’s Dock \
                icon, or run `open -a Kelp .` in a folder. A folder that isn’t a Git repository asks first: Initialize \
                Git, or Open Without Git (files, terminals and agents work; Source Control waits for `git init`). \
                File › Clone Repository… and Open over SSH… are the other ways in.
                """)
    }

    /// The list of keys, each as it is bound now. A command whose key was unbound is left out.
    private static func shortcuts(_ keys: ExtensionRegistry) -> String {
        func bound(_ ids: [String], _ between: String = " / ") -> String? {
            let texts = ids.compactMap(keys.keyText)
            return texts.isEmpty ? nil : texts.joined(separator: between)
        }
        let list: [(String?, String)] = [
            (bound(["workspace.new"]), String(localized: "chat")),
            (bound(["workspace.newGroup"]), String(localized: "group")),
            (bound(["workspace.newBranch"]), String(localized: "group on a branch")),
            (bound(["agents.new"]), String(localized: "agent")),
            (bound(["terminal.new"]), String(localized: "terminal")),
            (bound(["browser.new"]), String(localized: "browser")),
            (bound(["files.quickOpen"]), String(localized: "open file")),
            (bound(["workbench.commandPalette"]), String(localized: "commands")),
            (bound(["terminal.splitRight", "terminal.splitDown"]), String(localized: "split")),
            (bound(["agents.sideBySide"]), String(localized: "agents side by side / as tabs")),
            (bound(["view.maximizePane"]), String(localized: "maximize pane")),
            (bound(["editor.tab.1", "editor.tab.9"], "…"), String(localized: "tabs")),
            (bound(["editor.nextTab", "editor.previousTab"]), String(localized: "next / previous tab")),
            (bound(["workspace.switch"]), String(localized: "recent screens")),
            (bound(["view.nextPane", "view.previousPane"]), String(localized: "next / previous pane")),
            (
                bound(["view.paneLeft", "view.paneRight", "view.paneAbove", "view.paneBelow"], " "),
                String(localized: "pane on that side")
            ),
            (bound(["workspace.select.1", "workspace.select.9"], "…"), String(localized: "groups")),
            (bound(["workspace.next", "workspace.previous"]), String(localized: "next / previous group")),
            (bound(["agents.nextNeedingYou"]), String(localized: "agent that needs you")),
            ("⌘F", String(localized: "find")),
            (bound(["workspace.revealInFinder"]), String(localized: "reveal in Finder")),
            (bound(["workbench.toggleSidebar"]), String(localized: "sidebar")),
            (bound(["workbench.toggleInspector"]), String(localized: "inspector")),
            (bound(["editor.save"]), String(localized: "save")),
            (bound(["editor.closeTab"]), String(localized: "close tab")),
            (bound(["workspace.close"]), String(localized: "close group"))
        ]
        let line = list.compactMap { key, words in key.map { "\($0) \(words)" } }.joined(separator: " · ")
        return String(localized: "## Shortcuts") + "\n" + line + "\n\n"
            + String(
                localized: """
                    ⌃G in an agent opens its prompt in a tab, for long text; closing the tab puts it back, for you to \
                    send. Shortcuts work on any keyboard layout.
                    """)
    }

    nonisolated package static var location: URL { Paths.root.appendingPathComponent("HELP.md") }

    /// The guide's file. It is written next to the user's settings when opened, so it always matches this version, its
    /// language and its keys. When it can't be written, the old file opens as it was, with a banner saying why.
    static func file(_ keys: ExtensionRegistry) -> URL {
        do { try guide(keys).write(to: location, atomically: true, encoding: .utf8) } catch {
            let why = error.localizedDescription
            Banner.show(String(localized: "Couldn’t write \(location.path): \(why)"), style: .error)
        }
        return location
    }
}
