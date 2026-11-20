import AppKit
import Core
import DesignKit
import KelpKit

/// Draws the Databases panel's rows. These are a section's title (a folding section has a chevron and a count), an
/// agent's question with Allow, the project's card (its icon and name, its databases, Use a Database…) and a group's
/// card. A database's row has a dot, its name over where it is, its environment, and an icon for what agents may do.
/// A row under a database says what is wrong with it (with Start for a stopped compose service), and a run has its
/// own row. A database's badge sits under its card's icon, and its name under the card's name.
@MainActor
struct DatabasePanelRows {
    let panel: DatabasesPanel
    var app: AppModel { panel.app }

    func heading(_ heading: DatabasesPanel.Heading, libraryOpen: Bool, activityOpen: Bool, only: String?) -> NSView {
        let key = DatabasesPanel.Row.heading(heading).key
        switch heading {
        case .asks: return SectionHeading(String(localized: "Asks"))
        case .library(let count):
            return turned(
                SectionHeading(String(localized: "All My Databases"), count: count, open: libraryOpen), libraryOpen,
                key)
        case .activity(let count):
            let who = only.flatMap { app.session($0) }.map { app.catalog.name($0.agent) } ?? String(localized: "all")
            return turned(
                SectionHeading(String(localized: "Activity"), count: count, open: activityOpen, trailing: [small(who)]),
                activityOpen, key)
        }
    }

    /// Turns the chevron of the heading just folded or opened from where it was.
    private func turned(_ heading: SectionHeading, _ open: Bool, _ key: String) -> SectionHeading {
        if panel.turning == key, let chevron = heading.chevron {
            panel.turning = nil
            Task { chevron.turn(from: open ? .pi / 2 : -.pi / 2) }
        }
        return heading
    }

    /// An agent's waiting question: the agent's icon, what it would change, the statement, and Allow / Deny in the row.
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

    /// A database's row. It shows the engine's mark with its dot, the name over "host : database", the environment at
    /// the right edge (a column down the list, not a mark in each name), a key while its password waits, and what
    /// agents may do. A database of All My Databases ends, where that icon would be, with the project's icon when the
    /// project uses it (`used`), or else with Use in … while the pointer is over it.
    /// A branch's copy says whose it is. Under the database it copies (`under`) it names the branch alone; elsewhere
    /// it says so on its second line.
    func database(
        _ db: DatabaseInfo, library: Bool, health: DatabaseHealth?, used: Bool = false, color: ProjectColor? = nil,
        under: Bool = false
    ) -> NSView {
        let branch = app.worktree(panel.workspace)?.branch ?? ""
        let name = NSTextField.label(
            under ? String(localized: "Copy for \(branch)") : Self.shownName(db),
            font: .ui(TextSize.row), color: color?.color ?? .labelColor)
        var first: [NSView] = [name, NSView()]
        if db.passwordIn != nil {   // the password is still in the app it came from; macOS asks once, when it's opened
            let key = NSImageView(image: .symbol("key"))
            key.symbolConfiguration = .chrome(Metrics.iconSmall)
            key.contentTintColor = .secondaryLabelColor
            key.toolTip = String(
                localized: "Its password is read from the app it came from when you open it: macOS asks once.")
            first.append(key)
        }
        // Under the database it copies, a copy's environment is the one right above it.
        if !under, let chip = DatabaseLook.stageChip(db) { first.append(chip) }
        let top = NSStackView(views: first)
        top.spacing = Metrics.gap
        let detail = NSTextField.label(
            Self.copyWords(db, branch: branch, under: under) ?? Self.place(db) ?? db.engine.displayName,
            font: .ui(TextSize.caption), color: .secondaryLabelColor)
        detail.lineBreakMode = .byTruncatingMiddle   // "psqldbread…agrohistory.local : webdb": both ends matter
        detail.toolTip = DatabaseLook.detail(db)
        let words = stack([top, detail])
        words.setHuggingPriority(.defaultLow - 1, for: .horizontal)
        top.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        var views: [NSView] = [DatabaseLook.mark(db.engine, health), words]
        var hovered: [NSView] = []
        if library, used {
            let icon = projectIcon(size: 14)
            icon.toolTip = String(localized: "Used in \(projectTitle)")
            views.append(icon)
        } else if library {
            let use = IconButton(.symbol("plus"), tip: String(localized: "Use in \(projectTitle)")) {
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
        // Under the database it copies, a copy's badge sits where that database's name starts.
        let inset = Self.inCard + (under ? 19 + Metrics.gap : 0)
        let row = line(views, inset: inset, trailing: Metrics.insetTrailing, hovered: hovered)
        row.toolTip = card(db, health: health)
        return row
    }

    /// The words for a branch's copy. Under its database they say "agents here use it", or when the copy was made if
    /// agents don't see it. On its own they say "shop.sqlite3 · copy for fix/orders". Nil for a database that isn't a
    /// copy.
    static func copyWords(_ db: DatabaseInfo, branch: String, under: Bool) -> String? {
        guard let copy = db.copy else { return nil }
        guard under else {
            return [place(db), String(localized: "copy for \(branch)")].compactMap { $0 }.joined(separator: " · ")
        }
        return db.agentAccess == .hidden ? made(copy) : String(localized: "agents here use it")
    }

    private static func made(_ copy: BranchCopy) -> String {
        Date().timeIntervalSince(copy.at) < 60
            ? String(localized: "made just now") : String(localized: "made \(shortAgo(copy.at)) ago")
    }

    /// Where a card's content starts. A card's icon sits 4 pt further in than a plain row's, as the selection does.
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

    /// The project card's first row, laid out like the project's row in the sidebar: its icon and name, and how many
    /// databases it uses.
    func projectHead(count: Int) -> NSView {
        let icon = projectIcon(size: 16)
        let slot = NSStackView(views: [icon])
        slot.widthAnchor.constraint(equalToConstant: 19).isActive = true   // the column of the badges under it
        let name = NSTextField.label(projectTitle, font: .ui(TextSize.row))
        let views = [slot, name, NSView()] + (count > 0 ? [capsule(count)] : [])   // with none, the last row says so
        return line(views, inset: Self.inCard, trailing: Metrics.insetTrailing)
    }

    /// The project card's last row, a menu of All My Databases to use here. When the project uses none yet, the row
    /// says that agents in this project reach no database until it uses one.
    func use(empty: Bool) -> NSView {
        let icon = NSImageView(image: .symbol("plus"))
        icon.symbolConfiguration = .chrome(Metrics.iconSmall + 2)
        icon.contentTintColor = empty ? .themeAccent : .secondaryLabelColor
        let slot = NSStackView(views: [icon])
        slot.widthAnchor.constraint(equalToConstant: 19).isActive = true
        let said = NSTextField.label(
            String(localized: "Use a Database…"), font: .ui(TextSize.row),
            color: empty ? .themeAccent : .secondaryLabelColor)
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

    /// The first row of a group's card in All My Databases: a folder, the group's name, and how many databases it has.
    /// Under the pointer the folder turns into the chevron that folds the group, as a project's icon does in the
    /// sidebar. A coloured group's folder is filled with its colour, like Finder's tagged folders, and its card takes
    /// the colour too.
    func group(_ name: String, count: Int, open: Bool, color: ProjectColor? = nil) -> NSView {
        let folder = NSImageView(image: .symbol(color == nil ? "folder" : "folder.fill"))
        folder.symbolConfiguration = .chrome(Metrics.iconSmall + 2)
        folder.contentTintColor = color?.color ?? .secondaryLabelColor
        let fold = chevron(open, for: DatabasesPanel.Row.group(name, count: count).key)
        fold.contentTintColor = .secondaryLabelColor
        fold.isHidden = true
        let slot = NSStackView(views: [folder, fold])
        slot.widthAnchor.constraint(equalToConstant: 19).isActive = true
        let title = NSTextField.label(name, font: .ui(TextSize.row))
        let row = line([slot, title, NSView(), capsule(count)], inset: Self.inCard, trailing: Metrics.insetTrailing)
        (row as? HoverRow)?.hovered = [fold]
        (row as? HoverRow)?.resting = [folder]
        return row
    }

    /// Shows "AGR_GIS@pg-prod-ro" (Kelp's name for an unnamed TablePlus connection) as "AGR_GIS", because the host is
    /// on the line under it. Only the row shortens it; agents and `kelp db` keep using the whole name.
    static func shownName(_ db: DatabaseInfo) -> String {
        guard let at = db.name.lastIndex(of: "@"), at > db.name.startIndex, let host = db.host,
            host.hasPrefix(db.name[db.name.index(after: at)...])
        else { return db.name }
        return String(db.name[..<at])
    }

    /// The tooltip: where the database is, whether it answers, and who last ran something on it and when.
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
        let copied = db.copy.map { String(localized: "A copy of \($0.of), \(Self.made($0))") }
        return [
            copied, db.address, db.ssh.map { String(localized: "through \($0)") }, state, last,
            String(localized: "Agents: \(DatabaseLook.title(db.agentAccess))")
        ]
        .compactMap { $0 }.joined(separator: "\n")
    }

    /// Where the database is: "db.example.com/app_dev" (as its address says it), "via box", or a file's name.
    static func place(_ db: DatabaseInfo) -> String? {
        if db.engine.isFile { return db.path.map { ($0 as NSString).lastPathComponent } }
        // "webdb" over "host/webdb" would say the name twice, so the host stands alone.
        let database = db.database?.caseInsensitiveCompare(shownName(db)) == .orderedSame ? nil : db.database
        let at = [db.host, database].compactMap { $0 }.joined(separator: "/")
        return [at.isEmpty ? nil : at, db.ssh.map { String(localized: "via \($0)") }].compactMap { $0 }
            .joined(separator: " ")
    }

    /// The row under a database that doesn't answer: why, and Start when compose can start it. A stopped service is
    /// said in grey, because nothing broke: red is for one that doesn't answer.
    func problem(_ db: DatabaseInfo, _ databaseHealth: DatabaseHealth) -> NSView {
        // The reason reads "inkover doesn't answer at …", but the row above already names the database, so the line
        // keeps only the rest.
        var said = databaseHealth.reason ?? String(localized: "It doesn’t answer.")
        if said.hasPrefix(db.name + " ") { said = String(said.dropFirst(db.name.count + 1)).capitalizedFirst }
        let why = NSTextField.label(
            said, font: .ui(TextSize.caption),
            color: databaseHealth.state == .stopped ? .secondaryLabelColor : .textRed)
        why.toolTip = databaseHealth.reason
        var views: [NSView] = [why, NSView()]
        if databaseHealth.state == .stopped {
            // A row's worded action is the system's small button, as Allow and Deny are in an agent's question.
            let start = ClosureButton(title: String(localized: "Start")) { [weak panel] in panel?.start(db) }
            start.controlSize = .small
            start.bezelStyle = .push
            views.append(start)
        }
        let under = Self.inCard + 19 + Metrics.gap   // starts under the database's name
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
        end.setContentCompressionResistancePriority(.required, for: .horizontal)   // the SQL gives way, not the outcome
        return line([icon, sql, NSView(), end], inset: Metrics.inset, trailing: Metrics.inset)
    }

    // MARK: Parts

    /// The fold of the row `key`. The one a click just turned turns from where it pointed, once its row is laid out.
    private func chevron(_ open: Bool, for key: String) -> NSImageView {
        let image = NSImageView(image: .symbol(open ? "chevron.down" : "chevron.right"))
        image.symbolConfiguration = .chrome(Metrics.iconTiny)
        image.contentTintColor = .secondaryLabelColor
        image.widthAnchor.constraint(equalToConstant: 12).isActive = true
        if panel.turning == key {
            panel.turning = nil
            Task { image.turn(from: open ? .pi / 2 : -.pi / 2) }
        }
        return image
    }

    private func small(_ text: String) -> NSTextField {
        NSTextField.label(text, font: .ui(TextSize.caption), color: .secondaryLabelColor)
    }
    /// A count on the capsule every list's section has, as Source Control's does.
    private func capsule(_ n: Int) -> CountCapsule {
        let capsule = CountCapsule()
        capsule.text = n.formatted()
        return capsule
    }

    private func oneLine(_ sql: String) -> String {
        sql.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// A run's outcome: "200 · 2m", "3 changed · 1h", or what stopped it.
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

/// A row that shows its `hovered` views in place of its `resting` ones while the pointer is over it (`ListRowView`
/// tells it when).
final class HoverRow: NSStackView, Hoverable {
    var hovered: [NSView] = [], resting: [NSView] = []
    func setHover(_ on: Bool) {
        if !hovered.isEmpty { crossfade() }   // the folder and the chevron, or Use in and +, fade into each other
        for v in hovered { v.isHidden = !on }
        for v in resting { v.isHidden = on }
    }
}
