import Agents
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {
    /// The Markdown file in the focused tab; a beep when it's something else.
    static func markdown(_ app: AppModel) -> MarkdownTab? {
        let tab = (app.workbench.focusedContent as? FileTab)?.markdown
        if tab == nil { NSSound.beep() }
        return tab
    }

    /// The file in the focused tab; a beep when it's something else.
    static func fileTab(_ app: AppModel) -> FileTab? {
        let tab = app.workbench.focusedContent as? FileTab
        if tab == nil { NSSound.beep() }
        return tab
    }

    package static let files = Builtin(
        "kelp.files", "Files & Editor", "File tree, search and the code editor (tree-sitter, LSP).",
        icon: "doc.text", essential: true
    ) { app in
        return Contributions(
            panels: [
                PanelSpec(id: "files", title: "Files", icon: "folder", extensionId: "kelp.files") {
                    FilesPanel(app: app)
                },
                PanelSpec(id: "artifacts", title: "Artifacts", icon: "doc.richtext", extensionId: "kelp.files") {
                    ArtifactsPanel(app: app)
                }
            ],
            editors: [
                EditorSpec(id: "files.new", title: "New File", icon: "doc.badge.plus") { _ in UntitledTab.next(app) }
            ],
            commands: [
                cmd("files.quickOpen", "Open Quickly…", "cmd+p") { app.workbench.openQuickly() },
                cmd("files.new", "New File", "opt+cmd+n") { app.workbench.open(UntitledTab.next(app)) },
                cmd("markdown.cycleView", "Markdown: Source, Split, Preview", "shift+cmd+v") {
                    markdown(app)?.cycleMode()
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
                    guard let tab = app.workbench.focusedContent as? SavableTab else {
                        NSSound.beep()
                        return
                    }
                    Task { await tab.save() }
                },
                searchOption(app, "files.search.matchCase", "Find in Project: Match Case", "ctrl+opt+c", \.matchCase),
                searchOption(app, "files.search.wholeWord", "Find in Project: Whole Word", "ctrl+opt+w", \.wholeWord),
                searchOption(app, "files.search.regex", "Find in Project: Regular Expression", "ctrl+opt+r", \.regex),
                cmd("editor.saveAll", "Save All", "opt+cmd+s") {
                    Task { for file in app.workbench.editedFiles { await file.save() } }
                },
                cmd("editor.findReferences", "Find References", "shift+f12") { fileTab(app)?.server.findReferences() },
                cmd("editor.rename", "Rename Symbol…", "f2") { fileTab(app)?.server.rename() },
                cmd("editor.quickFix", "Quick Fix…", "opt+return") { fileTab(app)?.server.quickFix() },
                cmd("editor.showCompletions", "Show Completions", "ctrl+space") {
                    CodeEditor.focused?.showCompletions()
                },
                cmd("editor.showHover", "Show Hover", "ctrl+cmd+i") { CodeEditor.focused?.showHoverAtCursor() },
                cmd("editor.nextProblem", "Next Problem", "f8") { CodeEditor.focused?.goToProblem(forward: true) },
                cmd("editor.previousProblem", "Previous Problem", "shift+f8") {
                    CodeEditor.focused?.goToProblem(forward: false)
                },
                cmd("editor.toggleWordWrap", "Word Wrap", "opt+z") {
                    let language = fileTab(app)?.editor?.languageId
                    let on = app.settings[SettingKeys.wordWrap, language: language]
                    app.settings.set(SettingKeys.wordWrap, !on, language: language)
                },
                cmd("files.findInWorkspace", "Find in Project…", "shift+cmd+f") {
                    FilesPanel.shown(app) { $0.findInFiles() }
                },
                cmd("files.showProblems", "Show Problems") {
                    FilesPanel.shown(app) { $0.showProblems() }
                },
                cmd("files.findByName", "Find File by Name…") {
                    FilesPanel.shown(app) { $0.findByName() }
                },
                cmd("editor.goToLine", "Go to Line…", "cmd+l") {
                    if fileTab(app) != nil { app.workbench.openQuickly(text: ":") }
                },
                cmd("editor.jumpToDefinition", "Jump to Definition", "ctrl+cmd+j") { fileTab(app)?.jumpToDefinition() },
                // VS Code's Selection menu; on only in a code editor (AppDelegate.validateMenuItem). ⌘D, ⌘[ ⌘]: see EditorBox.
                cmd("editor.addNextOccurrence", "Add Next Occurrence", "cmd+d") {
                    CodeEditor.focused?.addNextOccurrence()
                },
                cmd("editor.selectAllOccurrences", "Select All Occurrences", "shift+cmd+l") {
                    CodeEditor.focused?.selectAllOccurrences()
                },
                cmd("editor.expandSelection", "Expand Selection", "ctrl+shift+cmd+right") {
                    CodeEditor.focused?.expandSelection()
                },
                cmd("editor.shrinkSelection", "Shrink Selection", "ctrl+shift+cmd+left") {
                    CodeEditor.focused?.shrinkSelection()
                },
                cmd("editor.cursorAbove", "Add Cursor Above", "ctrl+opt+up") {
                    CodeEditor.focused?.addCursor(above: true)
                },
                cmd("editor.cursorBelow", "Add Cursor Below", "ctrl+opt+down") {
                    CodeEditor.focused?.addCursor(above: false)
                },
                cmd("editor.cursorsAtLineEnds", "Add Cursors to Line Ends", "shift+opt+i") {
                    CodeEditor.focused?.cursorsAtLineEnds()
                },
                cmd("editor.moveLinesUp", "Move Line Up", "opt+up") { CodeEditor.focused?.moveLines(down: false) },
                cmd("editor.moveLinesDown", "Move Line Down", "opt+down") { CodeEditor.focused?.moveLines(down: true) },
                cmd("editor.copyLinesUp", "Copy Line Up", "shift+opt+up") {
                    CodeEditor.focused?.copyLines(down: false)
                },
                cmd("editor.copyLinesDown", "Copy Line Down", "shift+opt+down") {
                    CodeEditor.focused?.copyLines(down: true)
                },
                cmd("editor.deleteLines", "Delete Line", "shift+cmd+k") { CodeEditor.focused?.deleteLines() },
                cmd("editor.toggleComment", "Toggle Comment", "cmd+/") { CodeEditor.focused?.toggleComment() },
                cmd("editor.indent", "Indent", "cmd+]") { CodeEditor.focused?.indent(out: false) },
                cmd("editor.outdent", "Outdent", "cmd+[") { CodeEditor.focused?.indent(out: true) },
                cmd("editor.fold", "Fold", "opt+cmd+[") { CodeEditor.focused?.fold() },
                cmd("editor.unfold", "Unfold", "opt+cmd+]") { CodeEditor.focused?.unfold() },
                cmd("editor.insertSnippet", "Insert Snippet") { CodeEditor.focused?.showSnippets() },
                cmd("editor.unfoldAll", "Unfold All") { CodeEditor.focused?.unfoldAll() },
                cmd("editor.foldAll", "Fold All") { CodeEditor.focused?.foldAll() },
                cmd("editor.foldLevel2", "Fold Level 2") { CodeEditor.focused?.foldAll(level: 2) },
                cmd("editor.foldLevel3", "Fold Level 3") { CodeEditor.focused?.foldAll(level: 3) },
                // ⌥⌘↩: "path:12-30" into the agent's prompt (it reads the file itself), without pressing Return.
                cmd("editor.sendToAgent", "Send to Agent", "opt+cmd+return") {
                    if let tab = fileTab(app) {
                        FileActions(app).sendToAgent(
                            tab.path, lines: tab.selectedText?.isEmpty == false ? tab.selectedLines : nil)
                    }
                },
                cmd("editor.copyReference", "Copy Path and Line", "opt+shift+cmd+c") {
                    if let tab = fileTab(app) {
                        FileActions(app).copyReference(
                            tab.path, lines: tab.selectedText?.isEmpty == false ? tab.selectedLines : nil)
                    }
                },
                cmd("editor.copyWebLink", "Copy Web Link") {
                    if let tab = fileTab(app) { copyWebLink(app, tab.path, lines: tab.selectedLines) }
                },
                // The language's commands (`contributes.languages`): format the file (running it and its tests is Run's).
                // ⌃⇧I as in Xcode: an Option-only key like VS Code's ⇧⌥F never reaches the menu from a text view (it types Ï).
                cmd("editor.format", "Format Document", "ctrl+shift+i") {
                    if let tab = fileTab(app) { Task { await tab.format() } }
                }
            ],
            settings: [editorSettings, languagesSettings(app)],
            tabs: [
                TabProvider(
                    schemes: ["file"], make: { FileTab(uri: $0, app: app) },
                    placeholder: { uri in
                        let path = TabURI.filePath(uri).path, name = (path as NSString).lastPathComponent
                        if let page = ArtifactBar.listed(path, in: app) {   // an agent's page: its title, as once built
                            return (page.title, ArtifactBar.icon(page.kind), path)
                        }
                        return (name, app.fileIcons.image(name), path)
                    },
                    menu: { FileTab.menu(app, $0, uri: $1, workspace: $2, openBeside: $3) }),
                TabProvider(
                    schemes: ["untitled"], make: { UntitledTab(uri: $0, app: app) },
                    placeholder: { (UntitledTab.title($0), .symbol("doc"), nil) }),
                TabProvider(
                    schemes: ["prompt"], make: { PromptTab(uri: $0, app: app) },
                    placeholder: { _ in (String(localized: "Prompt"), .symbol("text.bubble"), nil) })
            ],
            languages: Languages.all,
            skills: [artifactsSkill]
        )
    }
}

// How the app keeps what the daemon pushes about files and artifacts: Files' own kinds, not the shell's.
extension FileEvent: Pushed {
    package var key: String { path }
    package static var forgottenWith: WatchTopic? { .file }
}
extension FilesEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .files }
}
extension ArtifactsEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .artifacts }
}
