import AppKit
import SwiftUI
import Core
import Agents
import WorkbenchKit

/// A built-in extension: same contribution points as an extension.json folder, implemented in Swift.
@MainActor
struct Builtin {
    let info: ExtensionInfo
    /// What it adds to `app`: its tabs, panels and commands are made with it.
    let contribute: @MainActor (_ app: AppModel) -> Contributions

    init(_ id: String, _ name: String, _ description: String, icon: String, essential: Bool = false,
         _ contribute: @escaping @MainActor (_ app: AppModel) -> Contributions) {
        info = ExtensionInfo(id: id, name: name, description: description, version: "built-in", icon: icon, builtin: true, essential: essential, enabled: true)
        self.contribute = contribute
    }
}

@MainActor
enum Builtins {
    static let all: [Builtin] = [workbench, agents, appearance, files, git, browser, issues, activity]

    /// A command that takes no arguments.
    static func cmd(_ id: String, _ title: String, _ key: String? = nil, _ run: @escaping @MainActor () -> Void) -> CommandSpec {
        CommandSpec(id: id, title: title, key: key) { _ in run() }
    }
    /// The editor area on screen; a beep when there is none.
    static var editor: EditorArea? {
        if Workbench.editor == nil { NSSound.beep() }
        return Workbench.editor
    }
    /// The file in the focused tab; a beep when it's something else.
    static var fileTab: FileTab? {
        let f = Workbench.editor?.focusedContent as? FileTab
        if f == nil { NSSound.beep() }
        return f
    }

    private static func s(_ key: String, _ title: String, _ type: String, _ def: JSONValue?, _ desc: String? = nil, options: [String]? = nil) -> SettingSpec {
        SettingSpec(key: key, title: title, type: type, default: def, description: desc, options: options)
    }

    static let agents = Builtin("kelp.agents", "Agents & Terminals", "Agent sessions and terminals as tabs.", icon: "sparkles", essential: true) { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["session"], make: { SessionTab(uri: $0, app: app) },
                              closeUnbuilt: { await SessionTab.close(app, session: TabURI.body($0)) },
                              menu: { SessionTab.menu(app, $0, uri: $1, workspace: $2, openBeside: $3) })]
        c.tabs.append(TabProvider(schemes: ["usage"]) { _ in UsageTab(app: app) })
        c.settings = [
            SettingsSection(id: "agents", title: "Agents", icon: "sparkles", specs: [
                s("agents.default", "Default agent", "enum", "claude", "Used by New Agent (⌥⌘T).", options: AgentCatalog.all.map(\.id)),
                s("agents.skills.extensions", "Skill: write Kelp extensions", "boolean", true,
                  "Claude Code knows where an extension goes, its format and how to connect it. Ask it for a panel, tab or command."),
                s("agents.skills.settings", "Skill: change Kelp settings", "boolean", true,
                  "Claude Code can read and change these settings (theme, fonts, extensions…) when you ask."),
                s("agents.skills.terminals", "Skill: run commands in Kelp tabs", "boolean", true,
                  "Claude Code runs tests or a dev server in a tab beside it, waits for them and reads what they printed, and shows its progress on its row."),
                s("sessions.hibernateMinutes", "Pause idle agents", "number", 0, "Paused agents free memory and resume the same conversation.",
                  options: ["0", "15", "30", "60", "240"]),
                s("power.keepAwake", "Keep Mac awake", "enum", "agents", options: ["agents", "always", "off"]),
                s("usage.readPlans", "Show plan limits", "boolean", true,
                  "Opens /usage of Claude Code (every 10 minutes), Grok and Antigravity (every 30) in the background, asks Codex for its limits "
                    + "(every 10 minutes) and shows how much of each plan is used at the bottom of the sidebar. Uses no tokens.")
            ], custom: { AnyView(VStack(alignment: .leading, spacing: 16) { AgentsSettings(app: app).frame(height: 300); AccountsSettings(app: app) }) }),
            SettingsSection(id: "terminal", title: "Terminal", icon: "terminal", specs: [
                s("terminal.fontFamily", "Font", "font", "", "Default: the theme's / Ghostty's font."),
                s("terminal.fontSize", "Font size", "number", 13),
                s("terminal.cursorStyle", "Cursor", "enum", "block", options: ["block", "bar", "underline"]),
                s("terminal.optionAsAlt", "Option key sends Alt (Meta)", "boolean", false),
                s("terminal.cleanCopy", "Copy text without the TUI around it", "boolean", true,
                  "Drops box borders, an agent's indented gutter and trailing spaces from what you copy, and joins the lines an agent wrapped at the edge (a long command copies as one line)."),
                s("terminal.useGhosttyConfig", "Also read ~/.config/ghostty/config", "boolean", false, "Keybindings and other Ghostty options; the theme's colors still apply."),
                s("terminal.tmux", "Run terminals inside tmux", "boolean", false,
                  "New terminals run in a tmux session of their own (on the host, for a remote project): it keeps running when Kelp quits or "
                    + "updates, and the tab attaches to it again; after a dropped SSH connection, Restart does. Closing the tab ends the session. "
                    + "Needs tmux; without it here, terminals are plain shells.")
            ])
        ]
        c.commands = [
            CommandSpec(id: "agents.new", title: "New Agent", key: "opt+cmd+t") { args in
                editor?.newAgent(args["agent"]?.string, prompt: args["prompt"]?.string)
            },
            cmd("terminal.new", "New Terminal", "cmd+t") { editor?.newTerminal() },
            cmd("terminal.tmux", "Attach to tmux Session…") { QuickOpen.shared.showTmux() },
            cmd("terminal.splitRight", "Split Right", "cmd+d") { editor?.splitFocused(.right) },
            cmd("terminal.splitDown", "Split Down", "shift+cmd+d") { editor?.splitFocused(.down) },
            cmd("agents.sideBySide", "Agents Side by Side", "ctrl+cmd+t") { editor?.toggleSideBySide() },
            cmd("agents.nextNeedingYou", "Show Agent Needing You", "shift+cmd+u") { Workbench.showNextNeedingAttention() },
            cmd("agents.usage", "Usage", "opt+cmd+u") { Workbench.open("usage:") },
            cmd("agents.history", "Session History", "shift+cmd+h") { HistoryWindow.shared.show(app) },
            // Like Caffeine: ticked keeps the Mac awake until unticked, which goes back to the setting's default.
            cmd("power.keepAwake", "Keep Mac Awake") {
                app.settings.set("power.keepAwake", app.settings.string("power.keepAwake") == "always" ? nil : .string("always"))
            }
        ]
        return c
    }

    static let files = Builtin("kelp.files", "Files & Editor", "File tree, search and the code editor (tree-sitter, LSP).", icon: "doc.text", essential: true) { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["file"], make: { FileTab(uri: $0, app: app) }, menu: FileTab.menu),
                  TabProvider(schemes: ["untitled"]) { UntitledTab(uri: $0, app: app) }]
        c.panels = [PanelSpec(id: "files", title: "Files", icon: "folder", extensionId: "kelp.files") { FilesPanel(app: app) }]
        c.editors = [EditorSpec(id: "files.new", title: "New File", icon: "doc.badge.plus") { _ in UntitledTab.next() }]
        c.settings = [SettingsSection(id: "editor", title: "Editor", icon: "doc.text", specs: [
            s("editor.fontFamily", "Font", "font", "", "Default: SF Mono."),
            s("editor.fontSize", "Font size", "number", 13),
            s("editor.minimap", "Show minimap", "boolean", false),
            s("editor.autoSave", "Save automatically", "boolean", false, "Off: edited files show a dot and you save with ⌘S. On: they save a moment after you stop typing."),
            s("editor.lsp", "Language servers (completion, jump to definition)", "boolean", true),
            s("editor.formatOnSave", "Format on save", "boolean", false, "⌘S runs Format Document first, for languages that have a formatter.")
        ])]
        let ts = LanguageSpec.Server(command: "typescript-language-server", args: ["--stdio"], install: "npm i -g typescript-language-server typescript")
        c.languages = [
            LanguageSpec(id: "swift", extensions: ["swift"], server: .init(command: "xcrun", args: ["sourcekit-lsp"]), format: "swift format -"),
            LanguageSpec(id: "typescript", extensions: ["ts"], server: ts), LanguageSpec(id: "typescriptreact", extensions: ["tsx"], server: ts),
            LanguageSpec(id: "javascript", extensions: ["js"], server: ts, run: "node ${file}"),
            LanguageSpec(id: "javascriptreact", extensions: ["jsx"], server: ts),
            LanguageSpec(id: "python", extensions: ["py"], server: .init(command: "pyright-langserver", args: ["--stdio"], install: "npm i -g pyright"),
                         run: "python3 ${file}", test: "python3 -m pytest ${file} -k ${symbol}", format: "ruff format -"),
            // The file's package, so a main split over several files runs too.
            LanguageSpec(id: "go", extensions: ["go"], server: .init(command: "gopls", install: "go install golang.org/x/tools/gopls@latest"),
                         run: "cd ${dir} && go run .", test: "cd ${dir} && go test -run ${symbol} .", format: "gofmt"),
            // From stdin rustfmt can't read Cargo.toml's edition, and 2015's parser rejects async fn.
            LanguageSpec(id: "rust", extensions: ["rs"], server: .init(command: "rust-analyzer", install: "rustup component add rust-analyzer"),
                         test: "cargo test ${symbol}", format: "rustfmt --edition 2021")
        ]
        c.commands = [cmd("files.quickOpen", "Open Quickly…", "cmd+p") { QuickOpen.shared.show(commandsOnly: false) },
                      cmd("files.new", "New File", "opt+cmd+n") { Workbench.open(UntitledTab.next()) },
                      cmd("markdown.cycleView", "Markdown: Source, Split, Preview", "shift+cmd+v") {
                          guard let md = (Workbench.editor?.focusedContent as? FileTab)?.markdown else { NSSound.beep(); return }
                          md.cycleMode()
                      },
                      cmd("editor.save", "Save", "cmd+s") {
                          guard let t = Workbench.editor?.focusedContent as? SavableTab else { NSSound.beep(); return }
                          Task {
                              if let file = t as? FileTab, app.settings.bool("editor.formatOnSave") == true, file.language?.format != nil { await file.format() }
                              await t.save()
                          }
                      },
                      cmd("editor.saveAll", "Save All", "opt+cmd+s") {
                          Task { for t in Workbench.editedFiles { await t.save() } }
                      },
                      cmd("files.findInWorkspace", "Find in Workspace…", "shift+cmd+f") {
                          Workbench.window?.showInspector(panel: "files")
                          DispatchQueue.main.async { (Workbench.window?.inspector.built("files") as? FilesPanel)?.findInFiles() }   // after the panel is built
                      },
                      cmd("editor.goToLine", "Go to Line…", "cmd+l") {
                          guard let t = fileTab else { return }
                          Task { if let s = await prompt(String(localized: "Go to line"), ""), let n = Int(s) { t.goTo(line: n) } }
                      },
                      cmd("editor.jumpToDefinition", "Jump to Definition", "ctrl+cmd+j") { fileTab?.jumpToDefinition() },
                      // ⌥⌘↩: "path:12-30" into the agent's prompt (it reads the file itself), without pressing Return.
                      cmd("editor.sendToAgent", "Send to Agent", "opt+cmd+return") {
                          if let t = fileTab { FileActions.sendToAgent(t.path, lines: t.selectedText?.isEmpty == false ? t.selectedLines : nil) }
                      },
                      cmd("editor.copyReference", "Copy Path and Line", "opt+shift+cmd+c") {
                          if let t = fileTab { FileActions.copyReference(t.path, lines: t.selectedText?.isEmpty == false ? t.selectedLines : nil) }
                      },
                      cmd("editor.copyWebLink", "Copy Web Link") { if let t = fileTab { FileActions.copyWebLink(t.path, lines: t.selectedLines) } },
                      // The language's commands (`contributes.languages`): run, test and format the file.
                      cmd("editor.runFile", "Run File") { if let t = fileTab { ScriptsMenu.shared.runFile(t, "run") } },
                      cmd("editor.testAtCursor", "Test at Cursor") { if let t = fileTab { ScriptsMenu.shared.runFile(t, "test") } },
                      // ⌃⇧I as in Xcode: an Option-only key like VS Code's ⇧⌥F never reaches the menu from a text view (it types Ï).
                      cmd("editor.format", "Format Document", "ctrl+shift+i") { if let t = fileTab { Task { await t.format() } } }]
        return c
    }

    static let git = Builtin("kelp.git", "Git", "Source Control: changes and staging, commits, branches, the history graph and diffs.", icon: "arrow.triangle.branch") { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["diff"]) { DiffTab(uri: $0, app: app) },
                  TabProvider(schemes: ["commit"]) { CommitMessageTab(uri: $0, app: app) }]
        let changed = ChangedFiles(app: app)
        c.panels = [PanelSpec(id: "git.changes", title: "Source Control", icon: "arrow.triangle.branch", extensionId: "kelp.git",
                              badge: { changed.count }) { SourceControlController(app: app) }]
        c.editors = [EditorSpec(id: "git.review", title: "Review Changes", icon: "plusminus", uri: { ctx in ctx.workspace.map { DiffTab.uri($0.id) } })]
        c.settings = [SettingsSection(id: "git", title: "Git", icon: "arrow.triangle.branch", specs: [
            s("git.branchPrefix", "Branch prefix", "string", "", "Added to branches Kelp names, e.g. “niko/”.")
        ])]
        c.commands = [
            CommandSpec(id: "git.review", title: "Git: Review Changes", key: "shift+cmd+r") { _ in
                if let w = app.workbench.workspaceId { Workbench.open(DiffTab.uri(w)) }
            },
            CommandSpec(id: "git.pullRequest", title: "Git: Create Pull Request") { _ in
                if let w = app.workbench.workspaceId { PRActions.create(worktree: w) }
            },
            CommandSpec(id: "git.push", title: "Git: Push") { _ in
                if let w = app.workbench.workspaceId {
                    Task { if await app.call(GitPush(id: w)) != nil { Banner.show(String(localized: "Pushed")) } }
                }
            }
        ]
        return c
    }

    /// Off on a clean install (`ExtensionRegistry.offByDefault`): Settings › Extensions turns it on.
    static let activity = Builtin("kelp.activity", "Activity", "CPU and memory of each agent and terminal, with Stop.", icon: "gauge.with.dots.needle.33percent") { app in
        var c = Contributions()
        c.panels = [PanelSpec(id: "activity", title: "Activity", icon: "gauge.with.dots.needle.33percent", extensionId: "kelp.activity") { ActivityController(app: app) }]
        return c
    }

    static let browser = Builtin("kelp.browser", "Browser", "Web pages as tabs, dev servers open automatically, Design Mode.", icon: "safari") { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["http", "https", "about", "preview"]) { BrowserTab(uri: $0, app: app) }]
        c.editors = [EditorSpec(id: "browser.new", title: "Browser", icon: "safari", uri: { _ in "about:blank#\(UUID().uuidString.prefix(6))" })]
        c.commands = [CommandSpec(id: "browser.new", title: "New Browser Tab", key: "shift+cmd+b") { args in
            Workbench.open(args["url"]?.string ?? "about:blank#\(UUID().uuidString.prefix(6))")
        }]
        return c
    }

    static let issues = Builtin("kelp.issues", "Issues & Pull Requests", "GitHub, Linear, Jira and Bitbucket: start work from an issue, review PRs.", icon: "checklist") { app in
        var c = Contributions()
        c.panels = [PanelSpec(id: "issues", title: "Issues & PRs", icon: "checklist", extensionId: "kelp.issues") {
            let t = TasksViewController(app: app)
            track(owner: t) { app.workbench.workspaceId } changed: { [weak t] in t?.show(worktree: $0) }
            return t
        }, PanelSpec(id: "ci", title: "CI Runs", icon: "checkmark.seal", extensionId: "kelp.issues") { CIRunsController(app: app) }]
        c.settings = [SettingsSection(id: "integrations", title: "Integrations", icon: "link", specs: [],
                                      custom: { AnyView(IntegrationsSettings(app: app)) })]
        // The workspace's project on GitHub / GitLab / Bitbucket, in the default browser.
        c.commands = [cmd("forge.openRepo", "Open Repository in Browser") { Forge.open(app, \.repo) },
                      cmd("forge.openCI", "Open CI/CD in Browser") { Forge.open(app, \.ci) },
                      cmd("forge.openPulls", "Open Pull Requests in Browser") { Forge.open(app, \.pulls) },
                      cmd("forge.openIssues", "Open Issues in Browser") { Forge.open(app, \.issues) }]
        return c
    }

    static let appearance = Builtin("kelp.appearance", "Appearance", "Themes for the window, terminal and editor.", icon: "paintpalette", essential: true) { _ in
        var c = Contributions()
        c.settings = [SettingsSection(id: "appearance", title: "Appearance", icon: "paintpalette", specs: [
            s("workbench.theme", "Color Theme", "theme", "auto",
              "The window, terminal and editor together. Match System switches Kelp Light / Dark with macOS; Ghostty keeps your Ghostty terminal colors."),
            s("workbench.iconTheme", "File Icon Theme", "enum", .string(FileIcon.system),
              "Icons in Files, Source Control and tabs. VS Code icon themes work as they are: Settings › Extensions › Install…"),
            s("workbench.textSize", "Sidebar and inspector text", "enum", "normal", "The terminal and the editor have their own font sizes.",
              options: ["normal", "large", "larger"]),
            s("workbench.inspectorIcons", "Inspector icons", "enum", "center", "Where the panel icons sit in their row.",
              options: ["left", "center", "right"]),
            s("workbench.inspectorIconsPosition", "Inspector icons position", "enum", "top",
              "Level with the tabs or under the panel. Drag an icon to move it; right-click the icons to hide them.",
              options: ["top", "bottom"]),
            s("workbench.sidebar.autoHide", "Auto-hide sidebar", "boolean", false, "Comes in while the pointer is at the window's left edge, like the Dock."),
            s("workbench.inspector.autoHide", "Auto-hide inspector", "boolean", false, "Comes in while the pointer is at the window's right edge."),
            s("workbench.sideBySideButton", "Agents Side by Side button", "boolean", true,
              "In the title bar, right of the search; right-click it to hide it. ⌃⌘T works either way.")
        ]), SettingsSection(id: "keyboard", title: "Keyboard", icon: "keyboard", specs: [],
                            custom: { AnyView(KeyboardSettings()) })]
        return c
    }
}
