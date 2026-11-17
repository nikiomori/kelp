import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit

/// How Find in Project matches: VS Code's three toggles (the editor's find options), remembered per workspace.
typealias SearchOptions = FindOptions

@MainActor
extension FindOptions {
    private static func key(_ workspace: String) -> String { "files.search.\(workspace)" }

    init(_ app: AppModel, workspace: String) {
        self.init()
        let on = app.uiState.strings(Self.key(workspace))
        matchCase = on.contains("case")
        wholeWord = on.contains("word")
        regex = on.contains("regex")
    }
    func save(_ app: AppModel, workspace: String) async {
        let on = [("case", matchCase), ("word", wholeWord), ("regex", regex)].filter(\.1).map { JSONValue.string($0.0) }
        await app.uiState.save(Self.key(workspace), on.isEmpty ? nil : .array(on))
    }
}

extension FilesPanel {
    func toggle(_ option: WritableKeyPath<SearchOptions, Bool>) {
        searchOptions[keyPath: option].toggle()
        if let id = worktree?.id {
            let options = searchOptions
            Task { await options.save(app, workspace: id) }
        }
        showSearchOptions()
        runSearch()
    }

    /// Shows the toggles only while there's a search. An empty field keeps its room for what you type, unless a toggle
    /// is on.
    func showSearchOptions() {
        let keys: [(TextToggle, Bool)] = [
            (caseToggle, searchOptions.matchCase), (wordToggle, searchOptions.wholeWord),
            (regexToggle, searchOptions.regex)
        ]
        let shown = !byName && (!search.stringValue.isEmpty || searchOptions != SearchOptions())
        for (button, on) in keys {
            button.isOn = on
            button.isHidden = !shown
        }
    }
}

/// Makes a search toggle a command, for the palette and Settings › Keyboard. The command brings up the panel first, as
/// ⇧⌘F does.
@MainActor
func searchOption(
    _ app: AppModel, _ id: String, _ title: String, _ key: String, _ option: WritableKeyPath<SearchOptions, Bool>
) -> CommandSpec {
    Builtins.cmd(id, title, key) {
        FilesPanel.shown(app) { $0.toggle(option) }
    }
}
