import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// Over the editor, if asked for (`editor.breadcrumbs`): the file's folders, each a menu of what's beside it, and the scopes
/// around the cursor, each a way back to its line. Scopes come from the code, so they need no language server.
@MainActor
final class Breadcrumbs: NSView {
    private let app: AppModel, path: String, root: String
    private weak var editor: CodeEditor?
    private let row = NSStackView()
    private var height: NSLayoutConstraint?
    private var scopes: [(line: Int, text: String)] = []

    init(app: AppModel, path: String, root: String, editor: CodeEditor) {
        self.app = app
        self.path = path
        self.root = root
        self.editor = editor
        super.init(frame: .zero)
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        row.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(line)
        let height = heightAnchor.constraint(equalToConstant: 0)
        self.height = height
        NSLayoutConstraint.activate([
            height, row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        let before = editor.onSelection
        editor.onSelection = { [weak self] in
            before?()
            self?.cursorMoved()
        }
        let language = editor.languageId
        track(owner: self) { [settings = app.settings, workbench = app.workbench] in
            settings[SettingKeys.breadcrumbs, language: language] && !workbench.inFocusMode
        } changed: { [weak self] on in
            guard let self else { return }
            if on { isHidden = false }
            rebuild()
            // The file under it moves into its room or out of it (focus mode, the setting), not by a bar's height
            // at once.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = self.window == nil ? 0 : Motion.duration(Motion.base)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.height?.animator().constant = on ? TextSize.of(Metrics.statusBar) : 0
                self.superview?.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                // AppKit runs it on the main thread
                MainActor.assumeIsolated { if let self, self.height?.constant == 0 { self.isHidden = true } }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The path's parts inside the project; only the file's name for a file outside it.
    static func parts(_ path: String, root: String) -> [String] {
        guard path.hasPrefix(root + "/") else { return [(path as NSString).lastPathComponent] }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    /// What's directly in `folder` ("" the top): folders first, each once.
    static func children(of folder: String, in paths: [String]) -> [(name: String, isFolder: Bool)] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var files = Set<String>(), folders = Set<String>()
        for path in paths where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                folders.insert(String(rest[..<slash]))
            } else {
                files.insert(String(rest))
            }
        }
        return folders.sorted().map { ($0, true) } + files.sorted().map { ($0, false) }
    }

    private func cursorMoved() {
        guard !isHidden, let now = editor?.scopesAtCursor, now.map(\.line) != scopes.map(\.line) else { return }
        rebuild()
    }

    private func rebuild() {
        guard !isHidden else { return }
        scopes = editor?.scopesAtCursor ?? []
        let parts = Self.parts(path, root: root)
        var views: [NSView] = []
        for (index, name) in (parts + scopes.map { Self.name($0.text) }).enumerated() {
            if index > 0 { views.append(Self.separator()) }
            let button = PointerButton(title: name, target: self, action: #selector(partClicked))
            button.tag = index
            button.isBordered = false
            button.font = .ui(TextSize.caption)
            button.lineBreakMode = .byTruncatingTail
            button.contentTintColor = .secondaryLabelColor
            button.setContentCompressionResistancePriority(.init(100), for: .horizontal)   // a long chain shortens, the row stays
            views.append(button)
        }
        row.setViews(views, in: .leading)
    }

    private static func separator() -> NSView {
        let label = NSTextField(labelWithString: "›")
        label.font = .ui(TextSize.caption)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// A scope's line without what opens it.
    private static func name(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("{") { trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) }
        return trimmed
    }

    @objc private func partClicked(_ button: NSButton) {
        let parts = Self.parts(path, root: root)
        guard button.tag < parts.count else {
            let index = button.tag - parts.count
            if scopes.indices.contains(index) { showSiblings(of: scopes[index].line, under: button) }
            return
        }
        let folder = parts[..<button.tag].joined(separator: "/")
        Task { await showSiblings(in: folder, under: button) }
    }

    /// The scopes beside it, from the code; the one the cursor is in ticked.
    private func showSiblings(of line: Int, under button: NSButton) {
        guard let editor else { return }
        let menu = NSMenu()
        for scope in editor.siblingScopes(ofLine: line) {
            let item = menu.add(Self.name(scope.text)) { [weak editor] in editor?.goTo(line: scope.line + 1) }
            item.state = scope.line == line ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    private func showSiblings(in folder: String, under button: NSButton) async {
        guard let worktree = app.worktrees.first(where: { $0.path == root }),
            let paths = await app.call(FilesList(id: worktree.id))
        else { return }
        let menu = NSMenu(), filler = FolderMenu(folder, paths, root: root, app: app)
        menu.delegate = filler
        filler.menuNeedsUpdate(menu)
        withExtendedLifetime(filler) {   // a menu's delegate is weak
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        }
    }
}

/// A folder's menu, filled when it opens: a project can hold more files than a menu should be built for up front.
@MainActor
private final class FolderMenu: NSObject, NSMenuDelegate {
    private let folder: String, paths: [String], root: String, app: AppModel

    init(_ folder: String, _ paths: [String], root: String, app: AppModel) {
        self.folder = folder
        self.paths = paths
        self.root = root
        self.app = app
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefix = folder.isEmpty ? "" : folder + "/"
        for child in Breadcrumbs.children(of: folder, in: paths) {
            guard child.isFolder else {
                menu.add(child.name) { [app, root] in app.workbench.open(TabURI.file(root + "/" + prefix + child.name))
                }
                continue
            }
            let item = NSMenuItem(title: child.name, action: nil, keyEquivalent: ""), sub = NSMenu()
            let filler = FolderMenu(prefix + child.name, paths, root: root, app: app)
            sub.delegate = filler
            item.representedObject = filler
            item.submenu = sub
            menu.addItem(item)
        }
    }
}
