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
            views = [
                title(name.isEmpty ? String(localized: "This Project") : name), NSView(),
                IconButton(.symbol("plus"), tip: String(localized: "Add Database…")) { [weak panel] in
                    panel?.addDatabase()
                }
            ]
        case .library(let count):
            views = [chevron(libraryOpen), title(String(localized: "All My Projects")), NSView(), digits(count)]
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

    func database(_ db: DatabaseInfo, library: Bool, open: Bool, health: DatabaseHealth?) -> NSView {
        let name = label(db.name, font: .ui(12, weight: .medium))
        let detail = label(
            library
                ? [DatabaseLook.engine(db.engine), db.group].compactMap { $0 }.joined(separator: " · ")
                : DatabaseLook.detail(db),
            font: .ui(11), color: .secondaryLabelColor)
        let fold = IconButton(
            .symbol(open ? "chevron.down" : "chevron.right"),
            tip: open ? String(localized: "Fold \(db.name)") : String(localized: "Show \(db.name)’s Tables")
        ) { [weak panel] in panel?.toggle(db, library: library) }
        fold.symbolConfiguration = .chrome(Metrics.iconTiny)
        var views: [NSView] = [fold, NSImageView(image: DatabaseLook.badge(db.engine, size: 14))]
        if !library { views.append(dot(health)) }
        views += [stack([name, detail]), NSView()]
        if db.production { views.append(DatabaseLook.productionChip()) }
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
        return line(views, inset: Metrics.gap, trailing: Metrics.insetTrailing)
    }

    /// Under a database that doesn't answer: why, and Start when compose can start it.
    func problem(_ db: DatabaseInfo, _ h: DatabaseHealth) -> NSView {
        let why = label(
            h.reason ?? String(localized: "It doesn’t answer."), font: .ui(11),
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
        return line(views, inset: Metrics.inset + 34, trailing: Metrics.inset)
    }

    func schema(_ name: String) -> NSView {
        let icon = NSImageView(image: .symbol("folder"))
        icon.contentTintColor = .secondaryLabelColor
        return line(
            [icon, label(name, font: .ui(12), color: .secondaryLabelColor), NSView()], inset: Metrics.inset + 18,
            trailing: Metrics.inset)
    }

    func table(_ t: DatabaseSchema.Table, depth: Int) -> NSView {
        let icon = NSImageView(image: .symbol("tablecells"))
        icon.contentTintColor = .secondaryLabelColor
        let name = t.name.split(separator: ".").last.map(String.init) ?? t.name
        var views: [NSView] = [icon, label(name, font: .ui(12)), NSView()]
        if let count = t.rows { views.append(digits(count)) }
        let row = line(views, inset: Metrics.inset + 22 * CGFloat(depth), trailing: Metrics.inset)
        row.toolTip = t.columns.map { $0.name + " " + $0.type }.joined(separator: "\n")
        return row
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

    /// Green answers, orange stopped, red down, grey not tried.
    private func dot(_ h: DatabaseHealth?) -> NSView {
        let color: NSColor =
            switch h?.state {
            case .ok: .systemGreen
            case .stopped: .systemOrange
            case .down: .systemRed
            default: .tertiaryLabelColor
            }
        let dot = NSImageView(image: .symbol("circle.fill"))
        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        dot.contentTintColor = color
        dot.toolTip =
            h.map { [$0.state == .ok ? String(localized: "Answers") : nil, $0.reason].compactMap { $0 }.joined() }
            ?? String(localized: "Not tried yet")
        return dot
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

    private func line(_ views: [NSView], inset: CGFloat, trailing: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: trailing)
        return stack
    }
}
