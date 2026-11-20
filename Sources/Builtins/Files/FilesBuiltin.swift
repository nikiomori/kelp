import Agents
import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import SwiftUI
import WorkbenchKit

extension Builtins {
    /// Returns the Markdown file in the focused tab, or beeps and returns nil when the tab holds something else.
    static func markdown(_ app: AppModel) -> MarkdownTab? {
        let tab = (app.workbench.focusedContent as? FileTab)?.markdown
        if tab == nil { NSSound.beep() }
        return tab
    }

    /// Returns the file in the focused tab, or beeps and returns nil when the tab holds something else.
    static func fileTab(_ app: AppModel) -> FileTab? {
        let tab = app.workbench.focusedContent as? FileTab
        if tab == nil { NSSound.beep() }
        return tab
    }

    /// A command for a button on the bar over the agent's page in front (`ArtifactBar.button(for:)`), enabled while
    /// the button shows there and can be pressed; elsewhere it beeps.
    fileprivate static func artifactCommand(_ app: AppModel, _ id: String, _ title: String) -> CommandSpec {
        let button: @MainActor () -> NSControl? = {
            (app.workbench.focusedContent as? FileTab)?.markdown?.artifactBar?.button(for: id)
        }
        return CommandSpec(
            id: id, title: title, enabled: { button().map { !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled } ?? false }
        ) { _ in
            guard let control = button(), !control.isHiddenOrHasHiddenAncestor, control.isEnabled else {
                return NSSound.beep()
            }
            control.sendAction(control.action, to: control.target)
        }
    }

    /// The project whose Disk Usage tab is in front.
    fileprivate static func diskShown(_ app: AppModel) -> String? {
        app.workbench.focusedContent.flatMap { TabURI.scheme($0.uri) == "disk" ? TabURI.body($0.uri) : nil }
    }

    package static let files = Builtin(
        "kelp.files", "Files & Editor", "File tree, search and the code editor (tree-sitter, LSP).",
        icon: "doc.text", essential: true
    ) { app in
        let disk = DiskSizes()
        return Contributions(
            panels: [
                PanelSpec(id: "files", title: "Files", icon: "folder", extensionId: "kelp.files") {
                    FilesPanel(app: app, disk: disk)
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
                // What the bar over an agent's page does, as its buttons do.
                artifactCommand(app, "artifact.present", "Artifact: Present"),
                artifactCommand(app, "artifact.olderVersion", "Artifact: Older Version"),
                artifactCommand(app, "artifact.newerVersion", "Artifact: Newer Version"),
                artifactCommand(app, "artifact.showLatest", "Artifact: Show Latest"),
                artifactCommand(app, "artifact.restore", "Artifact: Restore"),
                artifactCommand(app, "artifact.update", "Artifact: Update"),
                CommandSpec(
                    id: "disk.measureAgain", title: "Disk Usage: Measure Again",
                    enabled: { diskShown(app).map { !disk.measuring.contains($0) } ?? false }
                ) { _ in
                    guard let repoId = diskShown(app) else { return NSSound.beep() }
                    disk.measure(repoId, app: app, again: true)
                },
                // The formatting bar's commands, with GitHub's keys. They are enabled only in a Markdown file's editor.
                cmd("markdown.bold", "Bold", "cmd+b") { markdown(app)?.bold() },
                cmd("markdown.italic", "Italic", "cmd+i") { markdown(app)?.italic() },
                cmd("markdown.code", "Code") { markdown(app)?.code() },
                cmd("markdown.link", "Link…", "cmd+k") { markdown(app)?.link() },
                cmd("markdown.bullets", "Bulleted List") { markdown(app)?.bullets() },
                cmd("markdown.numbered", "Numbered List") { markdown(app)?.numbered() },
                cmd("markdown.tasks", "Task List") { markdown(app)?.tasks() },
                cmd("markdown.table", "Table") { markdown(app)?.table() },
                cmd("markdown.text", "Text") { markdown(app)?.heading(0) },
                cmd("markdown.heading1", "Heading 1") { markdown(app)?.heading(1) },
                cmd("markdown.heading2", "Heading 2") { markdown(app)?.heading(2) },
                cmd("markdown.heading3", "Heading 3") { markdown(app)?.heading(3) },
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
                // A git change and a merge conflict in the file in front, as the gutter's card and the conflict bar
                // offer them. No keys: ⌥↑ ⌥↓ move lines in the editor.
                cmd("editor.nextChange", "Next Change") { CodeEditor.focused?.goToChange(forward: true) },
                cmd("editor.previousChange", "Previous Change") { CodeEditor.focused?.goToChange(forward: false) },
                cmd("editor.revertChange", "Revert Change") {
                    fileTab(app)?.changeBars?.actOnChangeAtCursor(revert: true)
                },
                cmd("editor.stageChange", "Stage Change") {
                    fileTab(app)?.changeBars?.actOnChangeAtCursor(revert: false)
                },
                cmd("editor.nextConflict", "Next Conflict") { fileTab(app)?.conflicts?.step(1) },
                cmd("editor.previousConflict", "Previous Conflict") { fileTab(app)?.conflicts?.step(-1) },
                cmd("editor.acceptCurrent", "Accept Current") { fileTab(app)?.conflicts?.accept(.current) },
                cmd("editor.acceptIncoming", "Accept Incoming") { fileTab(app)?.conflicts?.accept(.incoming) },
                cmd("editor.acceptBoth", "Accept Both") { fileTab(app)?.conflicts?.accept(.both) },
                cmd("editor.trustProject", "Trust This Project") { fileTab(app)?.trustProject() },
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
                // The tree's own actions, on its selected row (or the folder it is in), as its ⋯ and right-click menus.
                cmd("files.newFolder", "New Folder…") { FilesPanel.shown(app) { $0.newFolder() } },
                cmd("files.newFromTemplate", "New from Template…") { FilesPanel.shown(app) { $0.newFromTemplate() } },
                cmd("files.collapseAll", "Collapse All") { FilesPanel.shown(app) { $0.collapseAll() } },
                cmd("files.rename", "Rename") { FilesPanel.shown(app) { $0.rename() } },
                cmd("files.moveToTrash", "Move to Trash") { FilesPanel.shown(app) { $0.trashSelected() } },
                cmd("editor.goToLine", "Go to Line…", "cmd+l") {
                    if fileTab(app) != nil { app.workbench.openQuickly(text: ":") }
                },
                cmd("editor.jumpToDefinition", "Jump to Definition", "ctrl+cmd+j") { fileTab(app)?.jumpToDefinition() },
                cmd("editor.jumpToDefinitionBeside", "Jump to Definition Beside") {
                    fileTab(app)?.jumpToDefinition(beside: true)
                },
                // VS Code's Selection menu, enabled only in a code editor (AppDelegate.validateMenuItem). EditorBox
                // explains how ⌘D, ⌘[ and ⌘] reach the editor first.
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
                // ⌥⌘↩ types "path:12-30" into the agent's prompt without pressing Return. The agent reads the file
                // itself.
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
                // The language's own commands (`contributes.languages`) only format the file. Running the file and its
                // tests belongs to Run. The key is ⌃⇧I, as in Xcode, because an Option key like VS Code's ⇧⌥F never
                // reaches the menu from a text view (it types Ï).
                cmd("editor.format", "Format Document", "ctrl+shift+i") {
                    if let tab = fileTab(app) { Task { await tab.format() } }
                }
            ],
            settings: [editorSettings(app), languagesSettings(app)],
            tabs: [
                TabProvider(
                    schemes: ["file"], make: { FileTab(uri: $0, app: app) },
                    placeholder: { uri in
                        let path = TabURI.filePath(uri).path, name = (path as NSString).lastPathComponent
                        if let page = ArtifactBar.listed(path, in: app) {   // an agent's page shows its listed title
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
                    placeholder: { _ in (String(localized: "Prompt"), .symbol("text.bubble"), nil) }),
                TabProvider(
                    schemes: ["disk"], make: { diskUsageTab(uri: $0, app: app, sizes: disk) },
                    placeholder: { _ in (String(localized: "Disk Usage"), .symbol("internaldrive"), nil) })
            ],
            languages: Languages.all,
            skills: [artifactsSkill],
            events: [
                {
                    guard let progress = $0 as? SuggestPullEvent else { return false }
                    Suggestions.of(app).downloaded(progress)
                    return true
                }
            ]
        )
    }
}

// How the app stores what the daemon pushes about files and artifacts. These kinds belong to Files, not to the shell.
extension FileEvent: Pushed {
    package var key: String { path }
    package static var forgottenWith: WatchTopic? { .file }
}
extension ArtifactsEvent: Pushed {
    package var key: String { worktree }
    package static var forgottenWith: WatchTopic? { .artifacts }
}
