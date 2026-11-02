import AppKit
import SwiftUI
import Core
import Agents
import EditorKit
import WorkbenchKit
import KelpKit

extension Builtins {
    /// The Markdown file in the focused tab; a beep when it's something else.
    static func markdown(_ app: AppModel) -> MarkdownTab? {
        let m = (app.workbench.editor?.focusedContent as? FileTab)?.markdown
        if m == nil { NSSound.beep() }
        return m
    }

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
                  TabProvider(schemes: ["untitled"]) { UntitledTab(uri: $0, app: app) },
                  TabProvider(schemes: ["prompt"]) { PromptTab(uri: $0, app: app) }]
        c.panels = [PanelSpec(id: "files", title: "Files", icon: "folder", extensionId: "kelp.files") { FilesPanel(app: app) }]
        c.editors = [EditorSpec(id: "files.new", title: "New File", icon: "doc.badge.plus") { _ in UntitledTab.next(app) }]
        c.settings = [SettingsSection(id: "editor", title: "Editor", icon: "doc.text", specs: [
            s("editor.fontFamily", "Font", "font", "", "Default: SF Mono."),
            s("editor.fontSize", "Font size", "number", 13, range: [8, 40]),
            s("editor.wordWrap", "Wrap long lines", "boolean", false, "On: a long line continues on the next row instead of running past the edge."),
            s("editor.hover", "Show what the language server knows on hover", "boolean", true,
              "A symbol's signature and documentation, and the arguments of a call as you type it."),
            s("editor.bracketColors", "Color brackets by depth", "boolean", false, "Pairs come from the code, so brackets in strings stay as they are."),
            s("editor.indentGuides", "Indent guides", "boolean", false, "Faint lines at each level; the block around the cursor's is brighter."),
            s("editor.stickyScroll", "Keep the enclosing scopes at the top", "boolean", true,
              "The lines that open the class and function you're in stay pinned as you scroll."),
            s("editor.tabSize", "Tab size", "number", 4, "Spaces to a level. A file's own indentation and its .editorconfig come first."),
            s("editor.insertSpaces", "Indent with spaces", "boolean", true),
            s("editor.detectIndentation", "Detect indentation from the file", "boolean", true),
            s("files.trimTrailingWhitespace", "Trim trailing whitespace on save", "boolean", false),
            s("files.insertFinalNewline", "End files with a newline on save", "boolean", false),
            s("editor.wordWrapColumn", "Wrap at column", "number", 0, "Wrapping stops here on a wide screen. 0: at the window's edge."),
            s("editor.rulers", "Rulers at columns", "string", "", "Thin lines at these columns, e.g. “80, 120”."),
            s("editor.renderWhitespace", "Show whitespace", "enum", "selection", "Unusual spaces, such as no-break ones, always show.",
              options: ["none", "selection", "trailing", "all"]),
            s("editor.wrappingIndent", "Wrapped lines continue", "enum", "same", "At the left edge, at their line's indentation, or one level past it.",
              options: ["none", "same", "indent"]),
            s("editor.autoSave", "Save automatically", "boolean", false,
              "Off: edited files show a dot and you save with ⌘S. On: they save a moment after you stop typing."),
            s("editor.lsp", "Language servers", "boolean", true, "Completion and jump to definition."),
            s("editor.formatOnSave", "Format on save", "boolean", false, "⌘S runs Format Document first, for languages that have a formatter."),
            s("markdown.defaultMode", "Default Markdown mode", "enum", "preview", options: ["preview", "edit", "split"])
        ], order: 70)]
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
                      // The formatting bar's, from the keyboard (as on GitHub); on only in a Markdown file's editor.
                      cmd("markdown.bold", "Bold", "cmd+b") { markdown(app)?.bold() },
                      cmd("markdown.italic", "Italic", "cmd+i") { markdown(app)?.italic() },
                      cmd("markdown.code", "Code") { markdown(app)?.code() },
                      cmd("markdown.link", "Link…", "cmd+k") { markdown(app)?.link() },
                      cmd("markdown.bullets", "Bulleted List") { markdown(app)?.bullets() },
                      cmd("markdown.numbered", "Numbered List") { markdown(app)?.numbered() },
                      cmd("markdown.tasks", "Task List") { markdown(app)?.tasks() },
                      cmd("editor.save", "Save", "cmd+s") {
                          guard let t = app.workbench.editor?.focusedContent as? SavableTab else { NSSound.beep(); return }
                          Task {
                              (t as? FileTab)?.rules?.cleanUpForSave()
                              let language = (t as? FileTab)?.editor?.languageId
                              if let file = t as? FileTab, app.settings.bool("editor.formatOnSave", language: language) == true, file.language?.format != nil {
                                  await file.format()
                              }
                              await t.save()
                          }
                      },
                      searchOption(app, "files.search.matchCase", "Find in Project: Match Case", "ctrl+opt+c", \.matchCase),
                      searchOption(app, "files.search.wholeWord", "Find in Project: Whole Word", "ctrl+opt+w", \.wholeWord),
                      searchOption(app, "files.search.regex", "Find in Project: Regular Expression", "ctrl+opt+r", \.regex),
                      cmd("editor.saveAll", "Save All", "opt+cmd+s") {
                          Task { for t in app.workbench.editedFiles { await t.save() } }
                      },
                      cmd("editor.findReferences", "Find References", "shift+f12") { fileTab(app)?.server.findReferences() },
                      cmd("editor.rename", "Rename Symbol…", "f2") { fileTab(app)?.server.rename() },
                      cmd("editor.quickFix", "Quick Fix…", "opt+return") { fileTab(app)?.server.quickFix() },
                      cmd("editor.showCompletions", "Show Completions", "ctrl+space") { CodeEditor.focused?.showCompletions() },
                      cmd("editor.showHover", "Show Hover", "ctrl+cmd+i") { CodeEditor.focused?.showHoverAtCursor() },
                      cmd("editor.nextProblem", "Next Problem", "f8") { CodeEditor.focused?.goToProblem(forward: true) },
                      cmd("editor.previousProblem", "Previous Problem", "shift+f8") { CodeEditor.focused?.goToProblem(forward: false) },
                      cmd("editor.toggleWordWrap", "Word Wrap", "opt+z") {
                          let language = fileTab(app)?.editor?.languageId
                          let on = app.settings.bool("editor.wordWrap", language: language) == true
                          app.settings.set("editor.wordWrap", .bool(!on), language: language)
                      },
                      cmd("files.findInWorkspace", "Find in Project…", "shift+cmd+f") {
                          app.workbench.showPanel("files")
                          DispatchQueue.main.async { (app.workbench.builtPanel("files") as? FilesPanel)?.findInFiles() }   // after the panel is built
                      },
                      cmd("files.findByName", "Find File by Name…") {
                          app.workbench.showPanel("files")
                          DispatchQueue.main.async { (app.workbench.builtPanel("files") as? FilesPanel)?.findByName() }   // after the panel is built
                      },
                      cmd("editor.goToLine", "Go to Line…", "cmd+l") { if fileTab(app) != nil { app.quickOpen.show(commandsOnly: false, text: ":") } },
                      cmd("editor.jumpToDefinition", "Jump to Definition", "ctrl+cmd+j") { fileTab(app)?.jumpToDefinition() },
                      // VS Code's Selection menu; on only in a code editor (AppDelegate.validateMenuItem). ⌘D, ⌘[ ⌘]: see EditorBox.
                      cmd("editor.addNextOccurrence", "Add Next Occurrence", "cmd+d") { CodeEditor.focused?.addNextOccurrence() },
                      cmd("editor.selectAllOccurrences", "Select All Occurrences", "shift+cmd+l") { CodeEditor.focused?.selectAllOccurrences() },
                      cmd("editor.expandSelection", "Expand Selection", "ctrl+shift+cmd+right") { CodeEditor.focused?.expandSelection() },
                      cmd("editor.shrinkSelection", "Shrink Selection", "ctrl+shift+cmd+left") { CodeEditor.focused?.shrinkSelection() },
                      cmd("editor.cursorAbove", "Add Cursor Above", "ctrl+opt+up") { CodeEditor.focused?.addCursor(above: true) },
                      cmd("editor.cursorBelow", "Add Cursor Below", "ctrl+opt+down") { CodeEditor.focused?.addCursor(above: false) },
                      cmd("editor.cursorsAtLineEnds", "Add Cursors to Line Ends", "shift+opt+i") { CodeEditor.focused?.cursorsAtLineEnds() },
                      cmd("editor.moveLinesUp", "Move Line Up", "opt+up") { CodeEditor.focused?.moveLines(down: false) },
                      cmd("editor.moveLinesDown", "Move Line Down", "opt+down") { CodeEditor.focused?.moveLines(down: true) },
                      cmd("editor.copyLinesUp", "Copy Line Up", "shift+opt+up") { CodeEditor.focused?.copyLines(down: false) },
                      cmd("editor.copyLinesDown", "Copy Line Down", "shift+opt+down") { CodeEditor.focused?.copyLines(down: true) },
                      cmd("editor.deleteLines", "Delete Line", "shift+cmd+k") { CodeEditor.focused?.deleteLines() },
                      cmd("editor.toggleComment", "Toggle Comment", "cmd+/") { CodeEditor.focused?.toggleComment() },
                      cmd("editor.indent", "Indent", "cmd+]") { CodeEditor.focused?.indent(out: false) },
                      cmd("editor.outdent", "Outdent", "cmd+[") { CodeEditor.focused?.indent(out: true) },
                      cmd("editor.fold", "Fold", "opt+cmd+[") { CodeEditor.focused?.fold() },
                      cmd("editor.unfold", "Unfold", "opt+cmd+]") { CodeEditor.focused?.unfold() },
                      cmd("editor.unfoldAll", "Unfold All") { CodeEditor.focused?.unfoldAll() },
                      cmd("editor.foldAll", "Fold All") { CodeEditor.focused?.foldAll() },
                      cmd("editor.foldLevel2", "Fold Level 2") { CodeEditor.focused?.foldAll(level: 2) },
                      cmd("editor.foldLevel3", "Fold Level 3") { CodeEditor.focused?.foldAll(level: 3) },
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
