import AppKit
import Core
import DesignKit
import KelpKit

/// The Databases panel's rows, drawn: a section's title (folding ones with a chevron and a count), an agent's
/// question with Allow, a database (chevron, dot, name over where it is, PROD, what agents may do as an icon), what's
/// wrong with one (Start for a stopped compose service), a schema, a table with its rows, a run.
@MainActor
struct DatabasePanelRows {
    let panel: DatabasesPanel
    var app: AppModel { panel.app }

    func heading(_ h: DatabasesPanel.Heading, libraryOpen: Bool, activityOpen: Bool, only: String?) -> NSView {
        var views: [NSView] = []
        switch h {
        case .asks: views = [title(String(localized: "Asks")), NSView()]
        case .project(let name):
            views = [title(name.isEmpty ? String(localized: "This Project") : name), NSView()]
        case .library(let count):
            views = [chevron(libraryOpen), title(String(localized: "All My Databases")), NSView(), digits(count)]
        case .activity(let count):
            let who = only.flatMap { app.session($0) }.map { app.catalog.name($0.agent) } ?? String(localized: "all")
            views = [chevron(activityOpen), title(String(localized: "Activity")), NSView(), small("\(who) · \(count)")]
        }
        return line(views, inset: Metrics.inset, trailing: Metrics.insetTrailing)
    }

    /// An agent waiting: its icon, what it would change, the statement, and Allow / Deny right there.
    func asks(_ run: DatabaseRun) -> NSView {
        let session = run.session.flatMap(app.session)
        let icon = NSImageView(image: app.catalog.icon(session?.agent, size: 14) ?? .symbol("exclamationmark.bubble"))
        let what =
            run.changed.map { String(localized: "Change \($0) rows in \(run.database)") }
            ?? String(localized: "Run a change in \(run.database)")
        let words = stack([
            label(what, font: .ui(12), color: .textOrange),
            label(oneLine(run.sql), font: .uiMono(10.5), color: .secondaryLabelColor)
        ])
        words.toolTip = run.sql
        let deny = ClosureButton(title: String(localized: "Deny")) { [weak panel] in panel?.answer(run, allow: false) }
        let allow = ClosureButton(title: String(localized: "Allow")) { [weak panel] in panel?.answer(run, allow: true) }
        for button in [deny, allow] {
            button.controlSize = .small
            button.bezelStyle = .push
        }
        return line([icon, words, NSView(), deny, allow], inset: Metrics.inset, trailing: Metrics.inset)
    }

    /// The engine's mark with its dot, the name over "host : database", the environment at the right edge (a column
    /// down the list, not a mark in each name), a key while its password waits, what agents may do; one of All My
    /// Databases offers Use Here while the pointer is over it.
    func database(_ db: DatabaseInfo, library: Bool, health: DatabaseHealth?) -> NSView {
        var first: [NSView] = [label(Self.shownName(db), font: .ui(12, weight: .medium)), NSView()]
        if db.passwordIn != nil {   // still in the app it came from: macOS asks once, when it's opened
            let key = NSImageView(image: .symbol("key"))
            key.symbolConfiguration = .chrome(Metrics.iconSmall)
            key.contentTintColor = .tertiaryLabelColor
            key.toolTip = String(
                localized: "Its password is read from the app it came from when you open it: macOS asks once.")
            first.append(key)
        }
        var hovered: [NSView] = []
        if library {   // on the name's line: under the pointer it mustn't squeeze the address
            let project = app.projectName(app.worktree(panel.workspace)?.repoId) ?? ""
            let use = ClosureButton(title: String(localized: "Use Here")) { [weak panel] in panel?.use(db) }
            use.controlSize = .mini
            use.toolTip = String(localized: "Use in \(project)")
            use.isHidden = true
            hovered.append(use)
            first.append(use)
        }
        first.append(DatabaseLook.stageChip(db.stage))
        let top = NSStackView(views: first)
        top.spacing = Metrics.gap
        let detail = label(Self.place(db) ?? DatabaseLook.engine(db.engine), font: .ui(11), color: .secondaryLabelColor)
        detail.lineBreakMode = .byTruncatingMiddle   // "psqldbread…agrohistory.local : webdb": both ends tell
        detail.toolTip = DatabaseLook.detail(db)
        let words = stack([top, detail])
        words.setHuggingPriority(.defaultLow - 1, for: .horizontal)
        top.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        var views: [NSView] = [mark(db.engine, health), words]
        if !library {
            let access = IconButton(
                .symbol(DatabaseLook.accessSymbol(db.agentAccess)),
                tip: String(localized: "Agents: \(DatabaseLook.title(db.agentAccess))")
            ) { [weak panel] in
                guard let panel else { return }
                DatabaseMenu.agents(db, app: panel.app, worktreeId: panel.workspace).popUp(
                    positioning: nil, at: NSEvent.mouseLocation, in: nil)
            }
            views.append(access)
        }
        let row = line(views, inset: Metrics.inset, trailing: Metrics.insetTrailing, hovered: hovered)
        row.toolTip = card(db, health: health)
        return row
    }

    /// The project's own list when it has none: agents here reach no database until one is used here.
    func hint() -> NSView {
        let said = label(
            String(localized: "None yet: agents here reach none."), font: .ui(11), color: .secondaryLabelColor)
        let row = line([said, NSView()], inset: Metrics.inset, trailing: Metrics.insetTrailing)
        row.toolTip = String(localized: "Use one of All My Databases here (Use Here on its row), or add one with +.")
        return row
    }

    /// "AGR_GIS@pg-prod-ro" (Kelp's name for an unnamed TablePlus one) as "AGR_GIS": its host is on the line under it.
    /// Only shown so: agents and `kelp db` keep calling it by its whole name.
    static func shownName(_ db: DatabaseInfo) -> String {
        guard let at = db.name.lastIndex(of: "@"), at > db.name.startIndex, let host = db.host,
            host.hasPrefix(db.name[db.name.index(after: at)...])
        else { return db.name }
        return String(db.name[..<at])
    }

    /// Where it is, whether it answers, who ran something on it last and when.
    private func card(_ db: DatabaseInfo, health: DatabaseHealth?) -> String {
        let runs = app.latest(DatabasesEvent.self, panel.workspace)?.runs.filter { $0.database == db.name } ?? []
        let last = runs.first.map { run in
            let who = run.session.flatMap(app.session).map { app.catalog.name($0.agent) } ?? String(localized: "You")
            return String(localized: "Last: \(who), \(shortAgo(run.at))")
        }
        let state: String? =
            switch health?.state {
            case .ok: String(localized: "Answers")
            case .some: health?.reason
            case nil: nil
            }
        return [
            db.address, db.ssh.map { String(localized: "through \($0)") }, state, last,
            String(localized: "Agents: \(DatabaseLook.title(db.agentAccess))")
        ]
        .compactMap { $0 }.joined(separator: "\n")
    }

    /// "db.example.com : app_dev" (as TablePlus lists it), "through box", or a file's name.
    static func place(_ db: DatabaseInfo) -> String? {
        if db.engine.isFile { return db.path.map { ($0 as NSString).lastPathComponent } }
        // "webdb" over "host : webdb" says its name twice: the host alone
        let database = db.database?.caseInsensitiveCompare(shownName(db)) == .orderedSame ? nil : db.database
        let at = [db.host, database].compactMap { $0 }.joined(separator: " : ")
        return [at.isEmpty ? nil : at, db.ssh.map { String(localized: "via \($0)") }].compactMap { $0 }
            .joined(separator: " ")
    }

    /// Under a database that doesn't answer: why, and Start when compose can start it.
    func problem(_ db: DatabaseInfo, _ h: DatabaseHealth) -> NSView {
        // "inkover doesn't answer at …": the row says whose, the line only what
        var said = h.reason ?? String(localized: "It doesn’t answer.")
        if said.hasPrefix(db.name + " ") { said = String(said.dropFirst(db.name.count + 1)).capitalizedFirst }
        let why = label(
            said, font: .ui(11),
            color: h.state == .stopped ? .textOrange : .textRed)
        why.toolTip = h.reason
        var views: [NSView] = [why, NSView()]
        if h.state == .stopped {
            let start = ClosureButton(title: String(localized: "Start")) { [weak panel] in panel?.start(db) }
            start.isBordered = false
            start.contentTintColor = .linkColor
            start.font = .ui(11)
            views.append(start)
        }
        return line(views, inset: Metrics.inset + 19 + Metrics.gap, trailing: Metrics.inset)   // under the name
    }

    func ran(_ run: DatabaseRun) -> NSView {
        let session = run.session.flatMap(app.session)
        let icon = NSImageView(image: session.flatMap { app.catalog.icon($0.agent, size: 14) } ?? .symbol("person"))
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let sql = label(oneLine(run.sql), font: .uiMono(11))
        sql.toolTip = [run.sql, run.error].compactMap { $0 }.joined(separator: "\n\n")
        let end = label(Self.outcome(run), font: .uiDigits(11), color: Self.color(run.state))
        return line([icon, sql, NSView(), end], inset: Metrics.inset, trailing: Metrics.inset)
    }

    // MARK: Parts

    /// The engine's badge with a dot on its corner: green answers, orange stopped, red down, grey not tried. A ring
    /// is cut out around the dot, so it reads on any row (selected, hovered).
    private func mark(_ engine: DatabaseInfo.Engine, _ h: DatabaseHealth?) -> NSImageView {
        nonisolated(unsafe) let badge = DatabaseLook.badge(engine, size: 16)
        nonisolated(unsafe) let color: NSColor =
            switch h?.state {
            case .ok: .systemGreen
            case .stopped: .systemOrange
            case .down: .systemRed
            default: .tertiaryLabelColor
            }
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { _ in
            badge.draw(in: NSRect(x: 0, y: 3, width: 16, height: 16))
            let dot = NSRect(x: 12, y: 0, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        let view = NSImageView(image: image)
        view.toolTip =
            h.map { [$0.state == .ok ? String(localized: "Answers") : nil, $0.reason].compactMap { $0 }.joined() }
            ?? String(localized: "Not tried yet")
        return view
    }

    private func chevron(_ open: Bool) -> NSImageView {
        let image = NSImageView(image: .symbol(open ? "chevron.down" : "chevron.right"))
        image.symbolConfiguration = .chrome(Metrics.iconTiny)
        image.contentTintColor = .tertiaryLabelColor
        image.widthAnchor.constraint(equalToConstant: 12).isActive = true
        return image
    }

    private func title(_ text: String) -> NSTextField {
        label(text.uppercased(), font: .ui(11, weight: .semibold), color: .tertiaryLabelColor)
    }

    private func small(_ text: String) -> NSTextField { label(text, font: .ui(11), color: .tertiaryLabelColor) }
    private func digits(_ n: Int) -> NSTextField {
        label(n.formatted(), font: .uiDigits(11), color: .tertiaryLabelColor)
    }

    private func oneLine(_ sql: String) -> String {
        sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// "200 · 2m", "3 changed · 1h", or what stopped it.
    static func outcome(_ run: DatabaseRun) -> String {
        switch run.state {
        case .done:
            let count = run.changed.map { String(localized: "\($0) changed") } ?? run.rows.map { "\($0)" }
            return [count, shortAgo(run.at)].compactMap { $0 }.joined(separator: " · ")
        case .asks: return String(localized: "asks")
        case .denied: return String(localized: "denied")
        case .refused: return String(localized: "refused")
        case .failed: return String(localized: "failed")
        }
    }

    static func color(_ state: DatabaseRun.State) -> NSColor {
        switch state {
        case .done, .denied: .secondaryLabelColor
        case .asks: .textOrange
        case .refused, .failed: .textRed
        }
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = Metrics.lineGap
        s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return s
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func line(_ views: [NSView], inset: CGFloat, trailing: CGFloat, hovered: [NSView] = []) -> NSView {
        let stack = HoverRow(views: views)
        stack.hovered = hovered
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: trailing)
        return stack
    }
}

extension String {
    /// "doesn't answer" → "Doesn't answer".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A row whose `hovered` views show only while the pointer is over it (`ListRowView` tells it).
final class HoverRow: NSStackView, Hoverable {
    var hovered: [NSView] = []
    func setHover(_ on: Bool) { for v in hovered { v.isHidden = !on } }
}
