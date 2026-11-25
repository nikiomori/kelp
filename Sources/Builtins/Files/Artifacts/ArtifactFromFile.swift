import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// Where an artifact starts other than a blank page, as fixed requests to an agent (no box to type a prompt in):
/// a file dropped on the Artifacts panel (a deck, a document, a spreadsheet, a PDF) becomes a page of the kind chosen,
/// made from it, the file kept beside the page (Claude Design's uploads, Gamma's remix); and a page becomes another
/// kind (⋯ › Make from This), with its tokens and the decisions in its marks (Canva's Magic Switch).
enum ArtifactStart {
    /// The files a page can start from, and the kind each suggests.
    static let kinds: [String: Artifacts.Kind] = [
        "pptx": .slides, "key": .slides, "pdf": .doc, "docx": .doc, "pages": .doc, "md": .doc, "txt": .doc,
        "rtf": .doc, "xlsx": .dashboard, "numbers": .dashboard, "csv": .dashboard
    ]
    /// Brand files: they suggest the project's design system rather than a page.
    static let brand: Set<String> = ["svg", "png", "jpg", "jpeg", "ttf", "otf", "woff", "woff2", "ase"]
    static let choices: [Artifacts.Kind] = [.slides, .doc, .dashboard, .design, .motion]

    static func title(_ kind: Artifacts.Kind) -> String {
        switch kind {
        case .slides: String(localized: "Slides")
        case .doc: String(localized: "Document")
        case .dashboard: String(localized: "Dashboard")
        case .design: String(localized: "Design")
        case .motion: String(localized: "Motion")
        default: kind.rawValue.capitalized
        }
    }

    /// What the agent is asked for a page made from `file` (kept beside `page`).
    static func brief(from file: String, page: String, kind: Artifacts.Kind) -> String {
        """
        Make the \(kind.rawValue) page \(page) from \(file), which is beside it: read it whole first, then keep its \
        content and its order, in the way \(kind.rawValue) pages are made here (`kelp artifact guide \(kind.rawValue)`).
        Say in two lines what you took from it and what you left out.
        """
    }

    /// What the agent is asked for the project's design system made from `file` (copied into .kelp/design).
    static func designSystem(from file: String) -> String {
        """
        Make the project's design system (`kelp artifact guide design system`) from \(file): read it whole, take \
        its colours, fonts, sizes and marks, and keep what it doesn't say from the project's code. Say in two lines \
        what you took from it.
        """
    }

    /// What the agent is asked for `page`, a new page of `kind` like `source` (any page is a template): its files
    /// copied, its look and parts kept; the user finishes the line with what the new one is about.
    static func brief(like source: String, page: String, kind: Artifacts.Kind) -> String {
        "Make \(page) like \(source) (`kelp artifact guide \(kind.rawValue)`): copy its files into "
            + "\((page as NSString).deletingLastPathComponent) first, keep its look, layout and parts, and change its "
            + "content to: "
    }

    /// What the agent is asked for `page`, a new page of `kind` made from `source`.
    static func brief(turning source: String, into page: String, kind: Artifacts.Kind, decided: [String]) -> String {
        var lines = [
            "Make \(page) from \(source): the same content as a \(kind.rawValue) page "
                + "(`kelp artifact guide \(kind.rawValue)`), with the project's design system; "
                + "leave \(source) as it is."
        ]
        if !decided.isEmpty { lines.append("Decisions already made on it: " + decided.joined(separator: "; ") + ".") }
        return lines.joined(separator: "\n")
    }
}

extension ArtifactsPanel {
    /// A file from Finder dropped on the list.
    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let file = Self.dropped(info),
            ArtifactStart.kinds[file.pathExtension.lowercased()] != nil
                || ArtifactStart.brand.contains(file.pathExtension.lowercased())
        else {
            return []
        }
        tableView.setDropRow(-1, dropOperation: .on)   // the whole list, not between rows
        return .copy
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let file = Self.dropped(info) else { return false }
        startFrom(file)
        return true
    }

    private static func dropped(_ info: NSDraggingInfo) -> URL? {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
    }

    /// Asks what to make of `file` and with which agent, then makes the page, puts the file beside it and starts the
    /// agent on it.
    func startFrom(_ file: URL) {
        guard let root = app.worktree(app.workbench.workspaceId)?.path, let window = view.window else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Make an Artifact from “\(file.lastPathComponent)”")
            alert.informativeText = String(localized: "An agent makes it from the file, which is kept beside it.")
            let kind = PointerPopUpButton(), agent = PointerPopUpButton()
            kind.addItems(withTitles: ArtifactStart.choices.map(ArtifactStart.title))
            kind.addItem(withTitle: String(localized: "Design System"))   // the last: not a page
            let suggested = ArtifactStart.kinds[file.pathExtension.lowercased()] ?? .doc
            let brand = ArtifactStart.brand.contains(file.pathExtension.lowercased())
            kind.selectItem(
                at: brand ? ArtifactStart.choices.count : ArtifactStart.choices.firstIndex(of: suggested) ?? 0)
            let agents = app.catalog.installed.filter { Session.isAgent($0.id) }
            agent.addItems(withTitles: agents.map(\.name))
            let grid = NSGridView(views: [
                [NSTextField.label(String(localized: "Make"), font: .ui(TextSize.row)), kind],
                [NSTextField.label(String(localized: "Agent"), font: .ui(TextSize.row)), agent]
            ])
            grid.rowSpacing = Metrics.gap
            grid.frame.size = NSSize(width: Metrics.alertAccessory, height: grid.fittingSize.height)
            alert.accessoryView = grid
            alert.addButton(withTitle: String(localized: "Start"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            let who = agents.indices.contains(agent.indexOfSelectedItem) ? agents[agent.indexOfSelectedItem].id : nil
            guard ArtifactStart.choices.indices.contains(kind.indexOfSelectedItem) else {
                let design = DesignSystem.dir(root: root).path
                _ = await app.quiet(FilesCreate(path: design, folder: true))   // there already, it says so: fine
                guard let copied = await app.call(FilesCopy(paths: [file.path], into: design))?.made.first else {
                    return
                }
                return app.workbench.starter?.newAgent(
                    who, prompt: ArtifactStart.designSystem(from: Artifacts.projectPath(copied))) ?? ()
            }
            let chosen = ArtifactStart.choices[max(kind.indexOfSelectedItem, 0)]
            let title = file.deletingPathExtension().lastPathComponent
            guard
                let page = await app.call(
                    ArtifactNew(kind: chosen, title: title, cwd: root, session: nil)),
                let copied = await app.call(
                    FilesCopy(paths: [file.path], into: (page as NSString).deletingLastPathComponent))?.made.first
            else { return }
            let brief = ArtifactStart.brief(
                from: Artifacts.projectPath(copied), page: Artifacts.projectPath(page), kind: chosen)
            app.workbench.starter?.newAgent(who, prompt: brief)
        }
    }
}

extension MarkdownTab {
    /// ⋯ › Make from This › <kind>: a new page of that kind from this one, made by the agent.
    func turnInto(_ kind: Artifacts.Kind) {
        let root = Self.projectRoot(of: url.path)
        Task {
            let title =
                (ArtifactBar.listed(url.path, in: app)?.title ?? url.deletingLastPathComponent().lastPathComponent)
                + " · " + ArtifactStart.title(kind)
            guard let page = await app.call(ArtifactNew(kind: kind, title: title, cwd: root, session: nil)) else {
                return
            }
            let brief = ArtifactStart.brief(
                turning: Artifacts.projectPath(url.path), into: Artifacts.projectPath(page), kind: kind,
                decided: await doneMarks())
            app.workbench.starter?.newAgent(nil, prompt: brief)
        }
    }

    /// ⋯ › Another Like This: a new page of this kind, which the agent makes from this one's files once the user says
    /// what it is about (the line waits in its prompt).
    func anotherLikeThis() {
        let root = Self.projectRoot(of: url.path)
        guard let listed = ArtifactBar.listed(url.path, in: app) else { return }
        let kind = listed.kind
        Task {
            guard
                let page = await app.call(ArtifactNew(kind: kind, title: listed.title + " 2", cwd: root, session: nil))
            else { return }
            let line = ArtifactStart.brief(
                like: Artifacts.projectPath(url.path), page: Artifacts.projectPath(page), kind: kind)
            app.workbench.starter?.newAgent(nil, prompt: line, draft: true)
        }
    }
}

extension ArtifactBar {
    /// ⋯'s Make from This section: the kinds this page can become.
    func turnItems(_ menu: NSMenu) {
        let own = Self.listed(markdown.url.path, in: markdown.app)?.kind
        menu.addItem(.sectionHeader(title: String(localized: "Make from This")))
        for kind in ArtifactStart.choices where kind != own {
            menu.add(ArtifactStart.title(kind)) { [weak markdown] in markdown?.turnInto(kind) }
        }
        if own != nil {
            menu.add(String(localized: "Another Like This…")) { [weak markdown] in markdown?.anotherLikeThis() }
        }
    }
}
