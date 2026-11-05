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
    private lazy var back = IconButton(.symbol("chevron.left"), tip: String(localized: "Older Version")) { [weak self] in self?.step(-1) }
    private lazy var forward = IconButton(.symbol("chevron.right"), tip: String(localized: "Newer Version")) { [weak self] in self?.step(1) }
    private let count = PointerButton()
    private let latest = PointerButton()
    private let restore = PointerButton()
    private let author = PointerButton()
    private lazy var more = IconButton(.symbol("ellipsis.circle"), tip: String(localized: "More")) { [weak self] in self?.showMore() }
    private var item: ArtifactItem?
    private var entries: [Entry] = []
    /// What's on screen: an index in `entries`; nil for the file as it is.
    private var shown: Int?

    private(set) lazy var view: NSView = {
        kind.font = .ui(12, weight: .medium)
        kind.textColor = .labelColor   // what this is: not a path, so not quiet like one
        status.textColor = .secondaryLabelColor
        for t in [kind, status] { t.lineBreakMode = .byTruncatingTail }
        status.font = .ui(12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ring.style = .spinning; ring.controlSize = .small
        count.font = .uiDigits(12); count.padding = Metrics.gap
        count.onClick = { [weak self] in self?.showVersions() }
        for (b, t) in [(latest, String(localized: "Show Latest")), (restore, String(localized: "Restore"))] {
            b.title = t; b.font = .ui(12)
            b.padding = Metrics.gap; b.restFill = .fillRest
        }
        latest.onClick = { [weak self] in self?.show(nil) }
        restore.onClick = { [weak self] in self?.restoreShown() }
        author.font = .ui(12); author.padding = Metrics.gap
        author.restFill = .fillRest; author.imagePosition = .imageLeading
        author.onClick = { [weak self] in self?.goToChat() }
        return Bar.content([kind, ring, status], [latest, restore, back, count, forward, author, more], stretching: status)
    }()

    init(app: AppModel, path: String, markdown: MarkdownTab) {
        self.app = app; self.path = path
        self.markdown = markdown
        watched = Watched(.artifacts, in: app)
        // The workspace whose folder holds the page: the deepest, for a branch's folder inside its project's. Compared
        // without symlinks: a tab opened as /tmp/… is in the project at /private/tmp/….
        let real = Paths.real(path) ?? path
        self.real = real
        workspace = app.worktrees.filter { real.hasPrefix((Paths.real($0.path) ?? $0.path) + "/") }.max { $0.path.count < $1.path.count }?.id
        super.init()
        watched.key = workspace
        track(owner: self) { [app, workspace] in app.artifacts[workspace ?? ""] } changed: { [weak self] _ in self?.update() }
        track(owner: self) { [app] in app.sessions.map { "\($0.id)\($0.status)\($0.title)" } } changed: { [weak self] _ in self?.update() }
    }

    /// Whether `path` is a page Kelp made (`.kelp/artifacts/<name>/<kind>.md`), not one of its kept versions.
    static func isPage(_ path: String) -> Bool {
        guard let r = path.range(of: "/\(Artifacts.folder)/") else { return false }
        let rest = path[r.upperBound...].split(separator: "/")
        return rest.count == 2 && Artifacts.Kind.allCases.contains { $0.file == rest[1] }
    }

    private func update() {
        item = app.artifacts[workspace ?? ""]?.first { (Paths.real($0.target) ?? $0.target) == real }
        let s = item?.session.flatMap(app.session)
        let type = item?.type ?? Artifacts.Kind.allCases.first { path.hasSuffix("/" + $0.file) }?.rawValue ?? ""
        kind.stringValue = Self.kindNames[type] ?? String(localized: "Doc")
        if let t = item?.title, !t.isEmpty { markdown.onPageTitle?(t) }
        // The file as it is goes last; a last version it hasn't changed from is the same page, named by its turn.
        let versions = item?.versions ?? []
        let live = item?.changed != false || versions.isEmpty
        entries = versions.dropLast(live ? 0 : 1).map { Entry(version: $0, label: $0.label, at: $0.at) }
            + [Entry(version: nil, label: live ? String(localized: "As it is now") : versions.last?.label ?? "", at: item?.modified)]
        if let i = shown, i >= entries.count - 1 { show(nil) }
        let writing = s?.status == .working && (item?.modified).map { Date().timeIntervalSince1970 - $0 < 120 } == true
        if shown != nil {
            status.stringValue = String(localized: "An older version, from \(Self.time(entries[shown ?? 0].at))")
        } else {
            status.stringValue = writing ? String(localized: "\(s.map(app.catalog.displayName) ?? "") is writing") : ""
        }
        ring.isHidden = !writing || shown != nil
        if ring.isHidden { ring.stopAnimation(nil) } else { ring.startAnimation(nil) }
        let index = shown ?? entries.count - 1
        count.title = String(localized: "\(index + 1) of \(entries.count)")
        for v in [back, forward, count] as [NSView] { v.isHidden = entries.count < 2 }
        back.isEnabled = index > 0; forward.isEnabled = index < entries.count - 1
        latest.isHidden = shown == nil; restore.isHidden = shown == nil
        author.isHidden = s == nil
        if let s {
            author.title = s.title.isEmpty ? app.catalog.displayName(s) : s.title
            author.image = s.agent.flatMap { app.catalog.icon($0, size: 14) }
            author.toolTip = s.status == .exited ? String(localized: "The chat that made it has ended") : String(localized: "Show the Chat That Made It")
            author.isEnabled = s.status != .exited
        }
    }

    private static let kindNames = ["doc": String(localized: "Doc"), "review": String(localized: "Review"), "slides": String(localized: "Slides"),
                                    "design": String(localized: "Design"), "dashboard": String(localized: "Dashboard")]

    private func step(_ by: Int) {
        let i = (shown ?? entries.count - 1) + by
        guard entries.indices.contains(i) else { return }
        show(i == entries.count - 1 ? nil : i)
    }

    /// Entry `i` in the preview (nil: the file as it is).
    private func show(_ i: Int?) {
        guard let i, let v = entries[i].version else {
            shown = nil; markdown.showVersion(nil)
            return update()
        }
        Task {
            guard let r = await app.call(FilesRead(path: Artifacts.versionPath(target: path, v.n))) else { return }
            shown = i; markdown.showVersion(r.text)
            update()
        }
    }

    private func restoreShown() {
        guard let text = markdown.shownVersion else { return }
        markdown.restore(text)
        show(nil)
    }

    private func showVersions() {
        let m = NSMenu()
        for (i, e) in entries.enumerated().reversed() {
            let when = [Self.time(e.at), e.version == nil && i == entries.count - 1 && !status.stringValue.isEmpty && shown == nil
                ? String(localized: "now writing") : nil].compactMap { $0 }.joined(separator: " · ")
            let item = m.add("\(i + 1)  \(e.label)") { [weak self] in self?.show(i == (self?.entries.count ?? 0) - 1 ? nil : i) }
            item.state = i == (shown ?? entries.count - 1) ? .on : .off
            item.toolTip = when
            item.attributedTitle = Self.menuTitle("\(i + 1)  \(e.label)", when)
        }
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Kelp keeps the last \(Artifacts.keptVersions) turns"), action: nil, keyEquivalent: "").isEnabled = false
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: count.bounds.height + 4), in: count)
    }

    private func showMore() {
        let m = NSMenu(), app = self.app, path = self.path, md = markdown
        for (i, t) in [String(localized: "Edit"), String(localized: "Split"), String(localized: "Preview")].enumerated() {
            let item = m.add(t) { md.modeSegment = i }
            item.state = md.modeSegment == i ? .on : .off
            item.isEnabled = md.shownVersion == nil   // an older version is only read
        }
        m.addItem(.separator())
        m.add(String(localized: "Print or Save as PDF…")) { md.printPage() }
        m.addItem(.separator())
        m.add(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        m.add(String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Artifacts.projectPath(path), forType: .string)
        }
        if let id = item?.session, app.session(id)?.status != .exited {
            m.add(String(localized: "Show the Chat That Made It")) { app.workbench.focus(session: id) }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    private func goToChat() { if let id = item?.session { app.workbench.focus(session: id) } }

    private static func time(_ t: Double?) -> String {
        guard let t else { return "" }
        let d = Date(timeIntervalSince1970: t)
        return Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(date: .abbreviated, time: .shortened)
    }

    private static func menuTitle(_ title: String, _ detail: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        guard !detail.isEmpty else { return s }
        s.append(NSAttributedString(string: "\n" + detail, attributes: [.font: NSFont.ui(11), .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }
}
