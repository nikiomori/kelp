import AppKit
import Core
import DesignKit
import KelpKit

/// How Find in Project matches: VS Code's three toggles, remembered per workspace.
@MainActor
struct SearchOptions: Equatable {
    var matchCase = false, wholeWord = false, regex = false
    private static func key(_ workspace: String) -> String { "files.search.\(workspace)" }

    init() {}
    init(_ app: AppModel, workspace: String) {
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

    /// They come with a search: an empty field keeps its room for the name of what you're after, unless one is on.
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

/// A toggle as a command (the palette, Settings › Keyboard): it brings the panel up first, as ⇧⌘F does.
@MainActor
func searchOption(
    _ app: AppModel, _ id: String, _ title: String, _ key: String, _ option: WritableKeyPath<SearchOptions, Bool>
) -> CommandSpec {
    Builtins.cmd(id, title, key) {
        app.workbench.showPanel("files")
        DispatchQueue.main.async { (app.workbench.builtPanel("files") as? FilesPanel)?.toggle(option) }   // after the panel is built
    }
}
