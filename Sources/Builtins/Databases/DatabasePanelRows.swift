import AppKit
import Core
import DesignKit
import KelpKit

/// The Databases panel's rows, drawn: a section's title (folding ones with a chevron and a count), an agent's
/// question with Allow, the project's card (its icon and name, its databases, Use a Database…), a group's card, a
/// database (dot, name over where it is, PROD, what agents may do as an icon), what's wrong with one (Start for a
/// stopped compose service), a run. A database's badge sits under its card's icon, its name under the card's name.
@MainActor
struct DatabasePanelRows {
    let panel: DatabasesPanel
    var app: AppModel { panel.app }

    func heading(_ h: DatabasesPanel.Heading, libraryOpen: Bool, activityOpen: Bool, only: String?) -> NSView {
        var views: [NSView] = []
        switch h {
        case .asks: views = [title(String(localized: "Asks")), NSView()]
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
            NSTextField.label(what, font: .ui(TextSize.row), color: .textOrange),
            NSTextField.label(oneLine(run.sql), font: .uiMono(TextSize.caption), color: .secondaryLabelColor)
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
    /// down the list, not a mark in each name), a key while its password waits, what agents may do. One of All My
    /// Databases ends where that icon would be: the project's icon when it's used there (`used`), else Use in … while
    /// the pointer is over it.
    func database(
        _ db: DatabaseInfo, library: Bool, health: DatabaseHealth?, used: Bool = false, color: ProjectColor? = nil
    ) -> NSView {
        let name = NSTextField.label(
            Self.shownName(db), font: .ui(TextSize.row, weight: .medium), color: color?.color ?? .labelColor)
        var first: [NSView] = [name, NSView()]
        if db.passwordIn != nil {   // still in the app it came from: macOS asks once, when it's opened
            let key = NSImageView(image: .symbol("key"))
            key.symbolConfiguration = .chrome(Metrics.iconSmall)
            key.contentTintColor = .tertiaryLabelColor
            key.toolTip = String(
                localized: "Its password is read from the app it came from when you open it: macOS asks once.")
            first.append(key)
        }
        if let chip = DatabaseLook.stageChip(db) { first.append(chip) }
        let top = NSStackView(views: first)
        top.spacing = Metrics.gap
        let detail = NSTextField.label(
            Self.place(db) ?? db.engine.displayName, font: .ui(TextSize.caption), color: .secondaryLabelColor)
        detail.lineBreakMode = .byTruncatingMiddle   // "psqldbread…agrohistory.local : webdb": both ends tell
        detail.toolTip = DatabaseLook.detail(db)
        let words = stack([top, detail])
        words.setHuggingPriority(.defaultLow - 1, for: .horizontal)
        top.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        var views: [NSView] = [mark(db.engine, health), words]
        var hovered: [NSView] = []
        if library, used {
            let icon = projectIcon(size: 14)
            icon.toolTip = String(localized: "Used in \(projectTitle)")
            views.append(icon)
        } else if library {
            let use = IconButton(.symbol("plus.circle"), tip: String(localized: "Use in \(projectTitle)")) {
                [weak panel] in panel?.use(db)
            }
            use.isHidden = true
            hovered.append(use)
            views.append(use)
        } else {
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
        let row = line(views, inset: Self.inCard, trailing: Metrics.insetTrailing, hovered: hovered)
        row.toolTip = card(db, health: health)
        return row
    }

    /// Where a card's content starts: its icon 4 pt further in than a plain row's, as the selection is.
    static let inCard = Metrics.inset + 4

    var projectTitle: String {
        app.projectName(app.worktree(panel.workspace)?.repoId) ?? String(localized: "This Project")
    }

    private func projectIcon(size: CGFloat) -> NSImageView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: size).isActive = true
        icon.heightAnchor.constraint(equalToConstant: size).isActive = true
        if let repo = app.repo(app.worktree(panel.workspace)?.repoId)?.path {
            ProjectIcon.show(repo, in: icon, app: app)
        }
        return icon
    }

    /// The project's card starts as its row does in the sidebar: its icon and name, how many databases it uses.
    func projectHead(count: Int) -> NSView {
        let icon = projectIcon(size: 16)
        let slot = NSStackView(views: [icon])
        slot.widthAnchor.constraint(equalToConstant: 19).isActive = true   // the badges' column under it
        let name = NSTextField.label(projectTitle, font: .ui(TextSize.row, weight: .semibold))
        let views = [slot, name, NSView()] + (count > 0 ? [digits(count)] : [])   // none: its last row says so
        return line(views, inset: Self.inCard, trailing: Metrics.insetTrailing)
    }

    /// The project card's last row: one of All My Databases to use here (a menu of them). With none used yet it says
    /// so: agents in this project reach no database until one is.
    func use(empty: Bool) -> NSView {
        let icon = NSImageView(image: .symbol("plus.circle"))
        icon.symbolConfiguration = .chrome(Metrics.iconSmall + 2)
        icon.contentTintColor = empty ? .linkColor : .secondaryLabelColor
        let slot = NSStackView(views: [icon])
        slot.widthAnchor.constraint(equalToConstant: 19).isActive = true
        let said = NSTextField.label(
            String(localized: "Use a Database…"), font: .ui(TextSize.row),
            color: empty ? .linkColor : .secondaryLabelColor)
        var words: NSView = said
        if empty {
            words = stack([
                said,
                NSTextField.label(
                    String(localized: "Agents here see no database yet"), font: .ui(TextSize.caption),
                    color: .secondaryLabelColor)
            ])
        }
        let row = line([slot, words, NSView()], inset: Self.inCard, trailing: Metrics.insetTrailing)
        row.toolTip = String(localized: "Pick one of All My Databases, or drag one onto this card.")
        return row
    }

    /// A group of All My Databases, its card's first row: folder, name, how many. Under the pointer the folder turns
    /// into the chevron that folds it, as a project's icon does in the sidebar. A coloured group's folder is filled
    /// with its colour, as Finder's tagged folders (its card takes the colour too).
    func group(_ name: String, count: Int, open: Bool, color: ProjectColor? = nil) -> NSView {
        let folder = NSImageView(image: .symbol(color == nil ? "folder" : "folder.fill"))
        folder.symbolConfiguration = .chrome(Metrics.iconSmall + 2)
        folder.contentTintColor = color?.color ?? .secondaryLabelColor
        let fold = chevron(open)
        fold.contentTintColor = .secondaryLabelColor
        fold.isHidden = true
        let slot = NSStackView(views: [folder, fold])
        slot.widthAnchor.constraint(equalToConstant: 19).isActive = true
        let title = NSTextField.label(name, font: .ui(TextSize.row, weight: .semibold))
        let row = line([slot, title, NSView(), digits(count)], inset: Self.inCard, trailing: Metrics.insetTrailing)
        (row as? HoverRow)?.hovered = [fold]
        (row as? HoverRow)?.resting = [folder]
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

    /// "db.example.com/app_dev" (as its address says it), "via box", or a file's name.
    static func place(_ db: DatabaseInfo) -> String? {
        if db.engine.isFile { return db.path.map { ($0 as NSString).lastPathComponent } }
        // "webdb" over "host/webdb" says its name twice: the host alone
        let database = db.database?.caseInsensitiveCompare(shownName(db)) == .orderedSame ? nil : db.database
        let at = [db.host, database].compactMap { $0 }.joined(separator: "/")
        return [at.isEmpty ? nil : at, db.ssh.map { String(localized: "via \($0)") }].compactMap { $0 }
            .joined(separator: " ")
    }

    /// Under a database that doesn't answer: why, and Start when compose can start it.
    func problem(_ db: DatabaseInfo, _ h: DatabaseHealth) -> NSView {
        // "inkover doesn't answer at …": the row says whose, the line only what
        var said = h.reason ?? String(localized: "It doesn’t answer.")
        if said.hasPrefix(db.name + " ") { said = String(said.dropFirst(db.name.count + 1)).capitalizedFirst }
        let why = NSTextField.label(
            said, font: .ui(TextSize.caption),
            color: h.state == .stopped ? .textOrange : .textRed)
        why.toolTip = h.reason
        var views: [NSView] = [why, NSView()]
        if h.state == .stopped {
            let start = PointerButton(title: String(localized: "Start")) { [weak panel] in panel?.start(db) }
            start.contentTintColor = .linkColor
            start.font = .ui(TextSize.caption)
            start.underlinesOnHover = true
            views.append(start)
        }
        let under = Self.inCard + 19 + Metrics.gap   // under the name
        return line(views, inset: under, trailing: Metrics.inset)
    }

    func ran(_ run: DatabaseRun) -> NSView {
        let session = run.session.flatMap(app.session)
        let icon = NSImageView(image: session.flatMap { app.catalog.icon($0.agent, size: 14) } ?? .symbol("person"))
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let sql = NSTextField.label(oneLine(run.sql), font: .uiMono(TextSize.caption))
        sql.toolTip = [run.sql, run.error].compactMap { $0 }.joined(separator: "\n\n")
        let end = NSTextField.label(Self.outcome(run), font: .uiDigits(TextSize.caption), color: Self.color(run.state))
        return line([icon, sql, NSView(), end], inset: Metrics.inset, trailing: Metrics.inset)
    }

    // MARK: Parts

    /// The engine's badge with a dot on its corner: green answers, orange stopped, red down, grey not tried. A ring
    /// is cut out around the dot, so it reads on any row (selected, hovered).
    private func mark(_ engine: DatabaseInfo.Engine, _ h: DatabaseHealth?) -> NSImageView {
        let badge = DatabaseLook.badge(engine, size: 16)
        let color: NSColor =
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
        NSTextField.label(text.uppercased(), font: .ui(TextSize.caption, weight: .semibold), color: .tertiaryLabelColor)
    }

    private func small(_ text: String) -> NSTextField {
        NSTextField.label(text, font: .ui(TextSize.caption), color: .tertiaryLabelColor)
    }
    private func digits(_ n: Int) -> NSTextField {
        NSTextField.label(n.formatted(), font: .uiDigits(TextSize.caption), color: .tertiaryLabelColor)
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
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.lineGap
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return column
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

/// A row whose `hovered` views show only while the pointer is over it (`ListRowView` tells it), in place of its
/// `resting` ones.
final class HoverRow: NSStackView, Hoverable {
    var hovered: [NSView] = [], resting: [NSView] = []
    func setHover(_ on: Bool) {
        for v in hovered { v.isHidden = !on }
        for v in resting { v.isHidden = on }
    }
}
