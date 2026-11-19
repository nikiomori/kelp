import AppKit
import Core
import DesignKit
import EditorKit
import KelpKit
import WorkbenchKit

/// The breadcrumb bar over the editor, shown when `editor.breadcrumbs` is on. It lists the file's folders, each a menu
/// of what sits beside it, and the scopes around the cursor, each a way back to that scope's line. Scopes come from the
/// code, so they need no language server.
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
            // When focus mode or the setting shows or hides the bar, the file below slides into or out of the bar's
            // room, so it doesn't jump by the bar's height at once. It leaves in two thirds of the time it came in.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = self.window == nil ? 0 : Motion.duration(on ? Motion.base : Motion.fast)
                ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
                ctx.allowsImplicitAnimation = true
                self.height?.animator().constant = on ? TextSize.of(Metrics.statusBar) : 0
                self.superview?.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                // AppKit runs the completion handler on the main thread.
                MainActor.assumeIsolated { if let self, self.height?.constant == 0 { self.isHidden = true } }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The parts of the path inside the project; for a file outside the project, only the file's name.
    static func parts(_ path: String, root: String) -> [String] {
        guard let inRoot = Paths.relative(path, to: root) else { return [(path as NSString).lastPathComponent] }
        return inRoot.split(separator: "/").map(String.init)
    }

    /// The folders and files directly in `folder` ("" is the project's top): folders first, each listed once.
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
            button.contentTintColor = .secondaryLabelColor
            // A long chain shortens and the row stays. The folders give way first, from the project's top down, as in
            // Xcode, then the scopes, and the file's name last, cut in its middle as Finder cuts a name.
            let file = index == parts.count - 1
            button.lineBreakMode = file ? .byTruncatingMiddle : .byTruncatingTail
            let rank = index < parts.count ? min(index, 49) : 50 + min(index - parts.count, 49)
            button.setContentCompressionResistancePriority(.init(file ? 200 : 100 + Float(rank)), for: .horizontal)
            views.append(button)
        }
        row.setViews(views, in: .leading)
    }

    /// A chevron between two parts, drawn as a symbol rather than typed.
    private static func separator() -> NSView {
        let chevron = NSImageView(image: .symbol("chevron.right"))
        chevron.symbolConfiguration = .chrome(Metrics.iconTiny)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.setAccessibilityElement(false)   // the parts are read one after another anyway
        return chevron
    }

    /// The scope's line of code without the `{` that opens the scope.
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

    /// Shows a menu of the scopes beside the one at `line`, read from the code, with the cursor's scope ticked.
    private func showSiblings(of line: Int, under button: NSButton) {
        guard let editor else { return }
        let menu = NSMenu()
        for scope in editor.siblingScopes(ofLine: line) {
            let item = menu.add(Self.name(scope.text)) { [weak editor] in editor?.goTo(line: scope.line + 1) }
            item.state = scope.line == line ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func showSiblings(in folder: String, under button: NSButton) async {
        guard let worktree = app.worktrees.first(where: { $0.path == root }),
            let paths = await app.call(FilesList(id: worktree.id))
        else { return }
        let menu = NSMenu(), filler = FolderMenu(folder, paths, root: root, app: app)
        menu.delegate = filler
        filler.menuNeedsUpdate(menu)
        withExtendedLifetime(filler) {   // NSMenu holds its delegate weakly
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }
}

/// Fills a folder's menu when it opens, because a project can hold more files than a menu should build up front.
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
