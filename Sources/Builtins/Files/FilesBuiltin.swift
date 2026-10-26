import AppKit
import SwiftUI
import Core
import Agents
import EditorKit
import WorkbenchKit
import KelpKit

extension Builtins {
    /// The file in the focused tab; a beep when it's something else.
    static func fileTab(_ app: AppModel) -> FileTab? {
        let f = app.workbench.editor?.focusedContent as? FileTab
        if f == nil { NSSound.beep() }
        return f
    }

    package static let files = Builtin("kelp.files", "Files & Editor", "File tree, search and the code editor (tree-sitter, LSP).",
                                       icon: "doc.text", essential: true) { app in
        var c = Contributions()
        c.tabs = [TabProvider(schemes: ["file"], make: { FileTab(uri: $0, app: app) }, menu: { FileTab.menu(app, $0, uri: $1, workspace: $2, openBeside: $3) }),
                  TabProvider(schemes: ["untitled"]) { UntitledTab(uri: $0, app: app) }]
        c.panels = [PanelSpec(id: "files", title: "Files", icon: "folder", extensionId: "kelp.files") { FilesPanel(app: app) }]
        c.editors = [EditorSpec(id: "files.new", title: "New File", icon: "doc.badge.plus") { _ in UntitledTab.next(app) }]
        c.settings = [SettingsSection(id: "editor", title: "Editor", icon: "doc.text", specs: [
            s("editor.fontFamily", "Font", "font", "", "Default: SF Mono."),
            s("editor.fontSize", "Font size", "number", 13),
            s("editor.minimap", "Show minimap", "boolean", false),
            s("editor.wordWrap", "Wrap long lines", "boolean", false, "On: a long line continues on the next row instead of running past the edge."),
            s("editor.autoSave", "Save automatically", "boolean", false,
              "Off: edited files show a dot and you save with ⌘S. On: they save a moment after you stop typing."),
            s("editor.lsp", "Language servers (completion, jump to definition)", "boolean", true),
            s("editor.formatOnSave", "Format on save", "boolean", false, "⌘S runs Format Document first, for languages that have a formatter."),
            s("markdown.defaultMode", "Default Markdown mode", "enum", "preview", options: ["preview", "edit", "split"])
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
        c.commands = [cmd("files.quickOpen", "Open Quickly…", "cmd+p") { app.quickOpen.show(commandsOnly: false) },
                      cmd("files.new", "New File", "opt+cmd+n") { app.workbench.open(UntitledTab.next(app)) },
                      cmd("markdown.cycleView", "Markdown: Source, Split, Preview", "shift+cmd+v") {
                          guard let md = (app.workbench.editor?.focusedContent as? FileTab)?.markdown else { NSSound.beep(); return }
                          md.cycleMode()
                      },
                      cmd("editor.save", "Save", "cmd+s") {
                          guard let t = app.workbench.editor?.focusedContent as? SavableTab else { NSSound.beep(); return }
                          Task {
                              if let file = t as? FileTab, app.settings.bool("editor.formatOnSave") == true, file.language?.format != nil {
                                  await file.format()
                              }
                              await t.save()
                          }
                      },
                      cmd("editor.saveAll", "Save All", "opt+cmd+s") {
                          Task { for t in app.workbench.editedFiles { await t.save() } }
                      },
                      cmd("files.findInWorkspace", "Find in Workspace…", "shift+cmd+f") {
                          app.workbench.showPanel("files")
                          DispatchQueue.main.async { (app.workbench.builtPanel("files") as? FilesPanel)?.findInFiles() }   // after the panel is built
                      },
                      cmd("editor.goToLine", "Go to Line…", "cmd+l") {
                          guard let t = fileTab(app) else { return }
                          Task { if let s = await prompt(String(localized: "Go to line"), ""), let n = Int(s) { t.goTo(line: n) } }
                      },
                      cmd("editor.jumpToDefinition", "Jump to Definition", "ctrl+cmd+j") { fileTab(app)?.jumpToDefinition() },
                      // VS Code's Selection menu; on only in a code editor (AppDelegate.validateMenuItem). ⌘D: see EditorBox.
                      cmd("editor.addNextOccurrence", "Add Next Occurrence", "cmd+d") { CodeEditor.focused?.addNextOccurrence() },
                      cmd("editor.selectAllOccurrences", "Select All Occurrences", "shift+cmd+l") { CodeEditor.focused?.selectAllOccurrences() },
                      cmd("editor.moveLinesUp", "Move Line Up", "opt+up") { CodeEditor.focused?.moveLines(down: false) },
                      cmd("editor.moveLinesDown", "Move Line Down", "opt+down") { CodeEditor.focused?.moveLines(down: true) },
                      cmd("editor.copyLinesUp", "Copy Line Up", "shift+opt+up") { CodeEditor.focused?.copyLines(down: false) },
                      cmd("editor.copyLinesDown", "Copy Line Down", "shift+opt+down") { CodeEditor.focused?.copyLines(down: true) },
                      cmd("editor.deleteLines", "Delete Line", "shift+cmd+k") { CodeEditor.focused?.deleteLines() },
                      // ⌥⌘↩: "path:12-30" into the agent's prompt (it reads the file itself), without pressing Return.
                      cmd("editor.sendToAgent", "Send to Agent", "opt+cmd+return") {
                          if let t = fileTab(app) { FileActions(app).sendToAgent(t.path, lines: t.selectedText?.isEmpty == false ? t.selectedLines : nil) }
                      },
                      cmd("editor.copyReference", "Copy Path and Line", "opt+shift+cmd+c") {
                          if let t = fileTab(app) { FileActions(app).copyReference(t.path, lines: t.selectedText?.isEmpty == false ? t.selectedLines : nil) }
                      },
                      cmd("editor.copyWebLink", "Copy Web Link") { if let t = fileTab(app) { FileActions(app).copyWebLink(t.path, lines: t.selectedLines) } },
                      // The language's commands (`contributes.languages`): run, test and format the file.
                      cmd("editor.runFile", "Run File") { if let t = fileTab(app) { app.scripts.runFile(t, "run") } },
                      cmd("editor.testAtCursor", "Test at Cursor") { if let t = fileTab(app) { app.scripts.runFile(t, "test") } },
                      // ⌃⇧I as in Xcode: an Option-only key like VS Code's ⇧⌥F never reaches the menu from a text view (it types Ï).
                      cmd("editor.format", "Format Document", "ctrl+shift+i") { if let t = fileTab(app) { Task { await t.format() } } }]
        return c
    }
}
