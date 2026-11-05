import Foundation
import Core

/// Help › How Kelp Works: a short guide, opened as a Markdown tab.
package enum Help {
    static let guide = """
    # How Kelp works

    ## Projects, workspaces, agents
    - **Project** — a folder, usually a git repository (the folder button over the sidebar, or File › Add Project…, ⌘O).
      It's a section in the sidebar.
    - **Workspace** — a clean desk in that folder: its own tabs, splits and agents. **+** next to the project (⌘N) opens one
      at once; it's named after the first thing you ask an agent. Rename with a double-click; close with ⇧⌘W (agents stop,
      files stay). Several workspaces can work in the same folder.
    - **Agent** — Claude Code, Grok, Antigravity, Qwen… whatever is installed and runs on this Mac (found automatically).

    ## What the sidebar tells you
    One line per agent: its icon, name, how long ago its state changed, and a mark:
    | Mark | Means |
    | --- | --- |
    | spinning ring | working |
    | orange ◎ | asked you something — needs your input (hover for the question) |
    | filled ✓, bold name | finished and you haven't looked yet |
    | moon, dimmed | paused to save memory — opens where it left off |
    | none | ready for a task |

    A project's header says how many agents need you. A collapsed workspace shows its agents' most urgent mark.
    ⇧⌘U goes to the next agent that needs you, wherever it is (also in the Dock icon's menu).

    **Limits** at the bottom: a ring per agent — how full its fullest limit is (orange from 70 %, red from 90 %), read
    from the agents' own /usage (Claude Code, Grok, Antigravity, Kimi, Copilot, Cursor) and Codex's logs. Hover or click for every limit and
    when it resets. Settings › Agents › Show plan limits turns it off.

    ## The middle: tabs and splits
    The **+** at the end of a pane's tabs opens an agent, a terminal, a browser or what extensions add; the agent's icon
    before it starts the default agent (Settings › Agents) in one click. ⌘D splits right,
    ⇧⌘D down; drag a tab to an edge to split, between groups to move it. Dividers stay where you drag them (View ›
    Equalize Panes evens them out); ⌥⌘ arrows move to the pane on that side. ⇧⌘↩ lets the focused pane fill the area
    and brings the others back. Agents open side by side, each in a pane of its own (four make a 2×2 grid); terminals and
    files share one more pane. The button right of the search (⌃⌘T; right-click hides it) shows them as tabs in one pane instead, and back;
    splitting or dragging a tab to another pane arranges the panes by hand from then on.
    ⌘W closes a tab (in an empty workspace, the workspace); ⇧⌘T brings it back in its place, an agent with its conversation,
    and File › Recently Closed lists the rest. Edited files show a dot on their tab and in the window's close
    button; ⌘S saves.

    In a terminal ⌘F finds text in its scrollback (⌘G / ⇧⌘G next / previous, ⌘E the selection). Right-click for copy,
    paste and splits. Drop files to type their paths; ⌘K clears, ⌘+ / ⌘− change the text size.

    ## The inspector
    Files (⌥⌘1), Source Control (⌥⌘2) — changes, staging, commit, history graph; click a file for its diff — Issues & Pull Requests, and
    panels from extensions.

    ## Extensions and agents
    Everything above is an extension; turn them off in Settings › Extensions. To add one, ask Claude Code in a tab:
    *"make a Kelp panel that lists my Docker containers"*. It knows how through Kelp's **skills** (Settings › Agents),
    which also let it change settings for you: *"switch Kelp to the Dracula theme"*.

    ## Settings
    Kelp › Settings… (⌘,) — or ~/.kelp/settings.json, or `kelp settings set <key> <value>` from any terminal.

    ## Adding projects
    File › Add Project… (⌘O), or drop a folder on the sidebar or on Kelp's Dock icon, or run `open -a Kelp .` in a folder.
    A folder that isn't a Git repository asks first: Initialize Git, or Open Without Git (files, terminals and agents work;
    Source Control waits for `git init`). File › Clone Repository… and Open over SSH… are the other ways in.

    ## Shortcuts
    ⌘N chat · ⇧⌘N group · ⌃⌘N chat on a branch · ⌥⌘T agent · ⌘T terminal · ⇧⌘B browser · ⌘P open file · ⇧⌘P commands · ⌘D / ⇧⌘D split ·
    ⌃⌘T agents side by side / as tabs · ⇧⌘↩ maximize pane · ⌘1…9 tabs · ⇧⌘] / ⇧⌘[ or ⌃⇥ / ⌃⇧⇥ next / previous tab · \
    ⌘] / ⌘[ next / previous pane · ⌥⌘←→↑↓ pane on that side ·
    ⌃1…9 groups · ⌃⌘↓ / ⌃⌘↑ next / previous group · ⇧⌘U agent that needs you · ⌘F find · ⌥⌘R reveal in Finder ·
    ⌃G in an agent opens its prompt in a tab, for long text; closing the tab puts it back, for you to send.
    ⌘0 sidebar · ⌥⌘0 inspector · ⌘S save · ⌘W close tab · ⇧⌘W close group. Shortcuts work on any keyboard layout.
    """

    package static var location: URL { Paths.root.appendingPathComponent("HELP.md") }

    /// Written next to the user's settings when opened, so it always matches this version.
    static var file: URL {
        try? guide.write(to: location, atomically: true, encoding: .utf8)
        return location
    }
}
