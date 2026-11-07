import AppKit
import Core
import DesignKit
import KelpKit

/// The bar over a page an agent made (`.kelp/artifacts/<name>/doc.md`): what it is, whether its agent is writing it,
/// its versions (one per turn of the agent, ‹ › and a list), the chat that made it, and ⋯. An older version shows in the
/// preview, read-only, until Show Latest; Restore makes it the file again.
@MainActor
final class ArtifactBar: NSObject {
    /// A version to show: a kept one, or the file as it is (nil).
    private struct Entry { var version: ArtifactVersion?, label: String, at: Double? }

    private let app: AppModel, path: String
    private unowned let markdown: MarkdownTab   // which holds this bar
    private let watched: Watched
    private let workspace: String?
    /// `path` without symlinks, as the daemon lists it.
    private let real: String
    private let kind = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let ring = NSProgressIndicator()
    private lazy var back = IconButton(.symbol("chevron.left"), tip: String(localized: "Older Version")) {
        [weak self] in self?.step(-1)
    }
    private lazy var forward = IconButton(.symbol("chevron.right"), tip: String(localized: "Newer Version")) {
        [weak self] in self?.step(1)
    }
    private let count = PointerButton()
    private let latest = PointerButton()
    private let restore = PointerButton()
    private let author = PointerButton()
    private lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in
        self?.showMore()
    }
    private var item: ArtifactItem?
    private var entries: [Entry] = []
    /// What's on screen: a version's number, which a new version or one dropped doesn't move; nil for the file as it is.
    private var shownN: Int?
    /// Where that version is in `entries` now.
    private var shown: Int? { shownN.flatMap { number in entries.firstIndex { $0.version?.n == number } } }

    private(set) lazy var view: NSView = {
        kind.font = .ui(12, weight: .medium)
        kind.textColor = .labelColor   // what this is: not a path, so not quiet like one
        status.textColor = .secondaryLabelColor
        for field in [kind, status] { field.lineBreakMode = .byTruncatingTail }
        status.font = .ui(12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ring.style = .spinning
        ring.controlSize = .small
        count.font = .uiDigits(12)
        count.padding = Metrics.gap
        count.onClick = { [weak self] in self?.showVersions() }
        for (button, title) in [(latest, String(localized: "Show Latest")), (restore, String(localized: "Restore"))] {
            button.title = title
            button.font = .ui(12)
            button.padding = Metrics.gap
            button.restFill = .fillRest
        }
        latest.onClick = { [weak self] in self?.show(nil) }
        restore.onClick = { [weak self] in self?.restoreShown() }
        author.font = .ui(12)
        author.padding = Metrics.gap
        author.restFill = .fillRest
        author.imagePosition = .imageLeading
        author.onClick = { [weak self] in self?.goToChat() }
        return Bar.content(
            [kind, ring, status], [latest, restore, back, count, forward, author, more], stretching: status)
    }()

    init(app: AppModel, path: String, markdown: MarkdownTab) {
        self.app = app
        self.path = path
        self.markdown = markdown
        watched = Watched(.artifacts, in: app)
        // The workspace whose folder holds the page: the deepest, for a branch's folder inside its project's. Compared
        // without symlinks: a tab opened as /tmp/… is in the project at /private/tmp/….
        let real = Paths.real(path) ?? path
        self.real = real
        workspace =
            app.worktrees.filter { real.hasPrefix((Paths.real($0.path) ?? $0.path) + "/") }.max {
                $0.path.count < $1.path.count
            }?.id
        super.init()
        watched.key = workspace
        track(owner: self) { [app, workspace] in
            app.latest(ArtifactsEvent.self, workspace ?? "")?.items
        } changed: { [weak self] _ in
            self?.update()
        }
        track(owner: self) { [app] in
            app.sessions.map { "\($0.id)\($0.status)\($0.title)" }
        } changed: { [weak self] _ in
            self?.update()
        }
    }

    /// Whether `path` is a page Kelp made (`.kelp/artifacts/<name>/<kind>.md`), not one of its kept versions.
    static func isPage(_ path: String) -> Bool {
        guard let range = path.range(of: "/\(Artifacts.folder)/") else { return false }
        let rest = path[range.upperBound...].split(separator: "/")
        return rest.count == 2 && Artifacts.Kind.allCases.contains { $0.file == rest[1] }
    }

    private func update() {
        item = app.latest(ArtifactsEvent.self, workspace ?? "")?.items.first {
            (Paths.real($0.target) ?? $0.target) == real
        }
        let session = item?.session.flatMap(app.session)
        let type = item?.type ?? Artifacts.Kind.allCases.first { path.hasSuffix("/" + $0.file) }?.rawValue ?? ""
        kind.stringValue = Self.kindNames[type] ?? String(localized: "Doc")
        if let title = item?.title, !title.isEmpty { markdown.onPageTitle?(title) }
        // The file as it is goes last; a last version it hasn't changed from is the same page, named by its turn.
        let versions = item?.versions ?? []
        let live = item?.changed != false || versions.isEmpty
        entries =
            versions.dropLast(live ? 0 : 1).map { Entry(version: $0, label: $0.label, at: $0.at) }
            + [
                Entry(
                    version: nil, label: live ? String(localized: "As it is now") : versions.last?.label ?? "",
                    at: item?.modified)
            ]
        if shownN != nil, shown.map({ $0 >= entries.count - 1 }) ?? true {
            shownN = nil
            markdown.showVersion(nil)
        }   // gone, or now the latest
        let writing =
            session?.status == .working && (item?.modified).map { Date().timeIntervalSince1970 - $0 < 120 } == true
        if shown != nil {
            status.stringValue = String(localized: "An older version, from \(Self.time(entries[shown ?? 0].at))")
        } else {
            status.stringValue = writing ? String(localized: "\(app.catalog.name(session?.agent)) is writing") : ""
        }
        ring.isHidden = !writing || shown != nil
        if ring.isHidden { ring.stopAnimation(nil) } else { ring.startAnimation(nil) }
        let index = shown ?? entries.count - 1
        count.title = String(localized: "\(index + 1) of \(entries.count)")
        for control in [back, forward, count] as [NSView] { control.isHidden = entries.count < 2 }
        back.isEnabled = index > 0
        forward.isEnabled = index < entries.count - 1
        latest.isHidden = shown == nil
        restore.isHidden = shown == nil
        author.isHidden = session == nil
        if let session {
            // The agent, not the chat's title, which reads as the page's own name; the chat is in the tip.
            author.title = app.catalog.name(session.agent)   // displayName is the chat's title once it has one
            author.image = session.agent.flatMap { app.catalog.icon($0, size: 14) }
            let tip =
                session.status == .exited
                ? String(localized: "The chat that made it has ended") : String(localized: "Show the Chat That Made It")
            author.toolTip = session.title.isEmpty ? tip : "\(tip): \(session.title)"
            author.isEnabled = session.status != .exited
        }
    }

    private static let kindNames = [
        "doc": String(localized: "Doc"), "review": String(localized: "Review"), "slides": String(localized: "Slides"),
        "design": String(localized: "Design"), "dashboard": String(localized: "Dashboard")
    ]

    private func step(_ by: Int) {
        let index = (shown ?? entries.count - 1) + by
        guard entries.indices.contains(index) else { return }
        show(index == entries.count - 1 ? nil : index)
    }

    /// Entry `i` in the preview (nil: the file as it is).
    private func show(_ index: Int?) {
        guard let index, let version = entries[index].version else {
            shownN = nil
            markdown.showVersion(nil)
            return update()
        }
        Task {
            guard let file = await app.call(FilesRead(path: Artifacts.versionPath(target: path, version.n))) else {
                return
            }
            shownN = version.n
            markdown.showVersion(file.text)
            update()
        }
    }

    private func restoreShown() {
        guard let text = markdown.shownVersion else { return }
        markdown.restore(text)
        show(nil)
    }

    private func showVersions() {
        let menu = NSMenu()
        for (index, entry) in entries.enumerated().reversed() {
            let when = [
                Self.time(entry.at),
                entry.version == nil && index == entries.count - 1 && !status.stringValue.isEmpty && shown == nil
                    ? String(localized: "now writing") : nil
            ].compactMap { $0 }.joined(separator: " · ")
            let item = menu.add("\(index + 1)  \(entry.label)") { [weak self] in
                self?.show(index == (self?.entries.count ?? 0) - 1 ? nil : index)
            }
            item.state = index == (shown ?? entries.count - 1) ? .on : .off
            item.toolTip = when
            item.attributedTitle = Self.menuTitle("\(index + 1)  \(entry.label)", when)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Kelp keeps the last \(Artifacts.keptVersions) turns"), action: nil,
            keyEquivalent: ""
        ).isEnabled = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: count.bounds.height + 4), in: count)
    }

    private func showMore() {
        let menu = NSMenu(), app = self.app, path = self.path, md = markdown
        for (mode, title) in [String(localized: "Edit"), String(localized: "Split"), String(localized: "Preview")]
            .enumerated()
        {
            let item = menu.add(title) { md.modeSegment = mode }
            item.state = md.modeSegment == mode ? .on : .off
            item.isEnabled = md.shownVersion == nil   // an older version is only read
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Print or Save as PDF…")) { md.printPage() }
        menu.addItem(.separator())
        menu.add(String(localized: "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        menu.add(String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Artifacts.projectPath(path), forType: .string)
        }
        if let id = item?.session, app.session(id)?.status != .exited {
            menu.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: id) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    private func goToChat() { if let id = item?.session { app.workbench.focus(session: id) } }

    private static func time(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let date = Date(timeIntervalSince1970: seconds)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func menuTitle(_ title: String, _ detail: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        guard !detail.isEmpty else { return text }
        text.append(
            NSAttributedString(
                string: "\n" + detail,
                attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }
}
