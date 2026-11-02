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

/// One of the toggles, in the bar beside the field: filled while on.
final class SearchToggle: PointerButton {
    var isOn = false { didSet { restFill = isOn ? .fillSelected : nil } }

    init(_ title: String, tip: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title
        font = .uiMono(11)
        toolTip = tip
        setAccessibilityLabel(tip)
        onClick = action
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: Metrics.iconButton).isActive = true
        heightAnchor.constraint(equalToConstant: Metrics.iconButton).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
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
        let keys: [(SearchToggle, Bool)] = [(caseToggle, searchOptions.matchCase), (wordToggle, searchOptions.wholeWord), (regexToggle, searchOptions.regex)]
        let shown = !byName && (!search.stringValue.isEmpty || searchOptions != SearchOptions())
        for (button, on) in keys {
            button.isOn = on
            button.isHidden = !shown
        }
    }
}

/// A toggle as a command (the palette, Settings › Keyboard): it brings the panel up first, as ⇧⌘F does.
@MainActor
func searchOption(_ app: AppModel, _ id: String, _ title: String, _ key: String, _ option: WritableKeyPath<SearchOptions, Bool>) -> CommandSpec {
    Builtins.cmd(id, title, key) {
        app.workbench.showPanel("files")
        DispatchQueue.main.async { (app.workbench.builtPanel("files") as? FilesPanel)?.toggle(option) }   // after the panel is built
    }
}
