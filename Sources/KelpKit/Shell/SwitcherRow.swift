import AppKit
import Core
import DesignKit

/// A ⌃Tab row, the sidebar's in a card: status | icon | name · where, and under it one line of what's there; then when,
/// and the number that picks it. With nothing to say under the name, one line.
@MainActor
struct SwitcherRow {
    var mark: StatusMark?
    var icon = NSImageView()
    var name: NSAttributedString
    var detail: NSAttributedString?
    var ci: NSView?
    var when = ""
    var spoken: [String] = []

    /// A workspace: its agent that matters most (what it asks, does or did), with the folder's changes and pull
    /// request.
    static func workspace(_ worktree: Worktree, app: AppModel) -> SwitcherRow {
        let agents = app.liveChats(in: worktree.id)
        let top = AgentStatus.mostUrgent(agents.map(SidebarCell.shownStatus))
        let lead = agents.filter { SidebarCell.shownStatus($0) == top }.max {
            ($0.statusAt ?? $0.createdAt) < ($1.statusAt ?? $1.createdAt)
        }
        // A chat with no project goes by the chat's name, as its sidebar row does; its folder has no branch worth
        // saying.
        let loose = NoProject.holds(app.repo(worktree.repoId))
        let title =
            loose
            ? lead.map(app.catalog.displayName) ?? worktree.displayName
            : app.groupName(worktree) ?? app.projectName(worktree.repoId) ?? worktree.displayName
        // The project for a group, the branch for a branch's folder: never the name again.
        var place: [String] = []
        for part in [app.projectName(worktree.repoId), loose ? nil : worktree.branch]
        where part.map({ $0 != title && $0 != worktree.displayName && !place.contains($0) }) == true {
            place.append(part ?? "")
        }
        let folder = app.gitState.folder(of: worktree.id)
        let badges = [
            folder.flatMap { GitFolders.changes(app.gitState.stats[$0.id], compact: true) },
            folder.flatMap { app.extensions.all.ci?.pr($0.id)?.title }
        ].compactMap { $0 }
        let said = lead.flatMap { SidebarCell.line($0, mode: "always", children: app.children(of: $0.id)) }
        var row = SwitcherRow(name: Self.name(title, place: place, badges: said == nil ? badges : []))
        if let lead {
            let mark = StatusMark(size: Metrics.iconLarge)
            mark.status = top
            mark.unread = agents.contains { SidebarCell.shownStatus($0) == top && $0.unread }
            mark.waitsForCommand = lead.waitsForCommand
            mark.announces = false   // the row's label says the state
            row.mark = mark
            row.when = shortAgo(lead.statusAt ?? lead.createdAt)
        }
        if let said { row.detail = Self.detail(prefix: said.prefix, said.text, badges: badges) }
        row.icon.image = .symbol("folder")
        if let project = app.repo(worktree.repoId) { ProjectIcon.show(project.path, in: row.icon, app: app) }
        if let state = folder.flatMap({ app.extensions.all.ci?.row($0.id) }) {
            let ci = CIMark()
            ci.state = state
            row.ci = ci
        }
        row.spoken = [title] + place + [said.map { (($0.prefix?.0).map { $0 + " " } ?? "") + $0.text } ?? "", row.when]
        return row
    }

    /// A server's page: its load, as the server's header in the sidebar reads it.
    static func server(_ host: String, app: AppModel) -> SwitcherRow {
        let stats = app.latest(HostEvent.self, host)?.stats
        let load: String? =
            stats.map { stats in
                guard stats.connected else { return stats.error ?? String(localized: "Not connected") }
                return [
                    stats.cpu.map { String(localized: "CPU \(Int($0.rounded()))%") },
                    HostStats.percent(stats.memory, stats.memoryTotal).map { String(localized: "Memory \($0)%") },
                    HostStats.percent(stats.disk, stats.diskTotal).map { String(localized: "Disk \($0)%") }
                ].compactMap { $0 }.joined(separator: " · ")
            }
        var row = SwitcherRow(name: Self.name(host, place: [String(localized: "Server")], badges: []))
        row.icon.image = .symbol("server.rack")
        row.icon.contentTintColor = .secondaryLabelColor
        row.detail = load.flatMap { $0.isEmpty ? nil : Self.detail(prefix: nil, $0, badges: []) }
        row.spoken = [host, String(localized: "Server"), load ?? ""]
        return row
    }

    /// "Kelp · main · +3 −1": the name, then where it is and what's changed, quieter.
    private static func name(_ title: String, place: [String], badges: [NSAttributedString]) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.ui(TextSize.body, weight: .medium), .foregroundColor: NSColor.labelColor])
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.ui(TextSize.row), .foregroundColor: NSColor.secondaryLabelColor
        ]
        for part in place { text.append(NSAttributedString(string: " · " + part, attributes: quiet)) }
        for badge in badges {
            text.append(NSAttributedString(string: " · ", attributes: quiet))
            text.append(badge)
        }
        return text
    }

    /// "Asks: which runner? · +40 −8 · #71": the agent's line as the sidebar says it, then the folder's badges.
    private static func detail(prefix: (String, NSColor)?, _ said: String, badges: [NSAttributedString])
        -> NSAttributedString
    {
        let font = NSFont.ui(TextSize.caption)
        let text = NSMutableAttributedString()
        if let (word, color) = prefix {
            text.append(NSAttributedString(string: word + " ", attributes: [.font: font, .foregroundColor: color]))
        }
        text.append(
            NSAttributedString(string: said, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        for badge in badges {
            text.append(
                NSAttributedString(
                    string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(badge)
        }
        return text
    }

    /// The row: `number` 1–9 is the key that picks it; `here` is the screen you're on, dimmed, saying so.
    func view(number: Int, here: Bool) -> NSView {
        let slot = NSView()   // no agent hides the mark; its column stays, so the icons line up
        if let mark { slot.pin(mark) }
        let side = Metrics.iconLarge
        let fixed = [
            slot.widthAnchor.constraint(equalToConstant: side), slot.heightAnchor.constraint(equalToConstant: side),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconMenu),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconMenu)
        ]
        NSLayoutConstraint.activate(fixed)
        let text = NSStackView(views: [Self.label(name)] + (detail.map { [Self.label($0)] } ?? []))
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let shownWhen = here ? String(localized: "Current") : when
        let time = Self.label(Self.quiet(shownWhen))
        // A long name truncates, not the time.
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let key = Self.label(Self.quiet((1...9).contains(number) && !here ? "\(number)" : ""))
        key.alignment = .center
        key.widthAnchor.constraint(equalToConstant: side).isActive = true   // the numbers line up, and the times
        let line = NSStackView(views: [slot, icon, text] + (ci.map { [$0] } ?? []) + [time, key])
        line.distribution = .fill
        line.spacing = Metrics.gapWide
        line.alignment = .centerY
        line.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.gapWide, bottom: 0, right: Metrics.gap)
        line.heightAnchor.constraint(equalToConstant: detail == nil ? Metrics.rowMenu : Metrics.rowTwoLine).isActive =
            true
        line.wantsLayer = true
        line.layer?.cornerRadius = Metrics.radiusSM
        line.layer?.cornerCurve = .continuous
        if here { line.alphaValue = Metrics.tabDim }
        line.setAccessibilityElement(true)
        line.setAccessibilityLabel((spoken + (here ? [shownWhen] : [])).filter { !$0.isEmpty }.joined(separator: ", "))
        return line
    }

    private static func quiet(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: NSFont.uiDigits(TextSize.caption), .foregroundColor: NSColor.tertiaryLabelColor])
    }

    private static func label(_ text: NSAttributedString) -> NSTextField {
        let styled = NSMutableAttributedString(attributedString: text)
        // Its own: an attributed string without one is cut off at the edge, not ended with "…".
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        styled.addAttribute(.paragraphStyle, value: tail, range: NSRange(location: 0, length: styled.length))
        let field = NSTextField(labelWithAttributedString: styled)
        field.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

/// The switcher's card: its rows, at most nine before they scroll, and the keys under them while they're new.
@MainActor
final class SwitcherCard: NSVisualEffectView {
    init(rows: [NSView], hint: String?, maxHeight: CGFloat) {
        super.init(frame: .zero)
        material = .popover   // as Quick Open's
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Metrics.radiusXL
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1   // an edge, as menus have, so it holds against a window of the same grey
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = Metrics.lineGap
        list.alignment = .leading
        list.edgeInsets = NSEdgeInsets(top: Metrics.gap, left: Metrics.gap, bottom: Metrics.gap, right: Metrics.gap)
        for row in rows {
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -2 * Metrics.gap).isActive = true
        }
        list.widthAnchor.constraint(equalToConstant: Metrics.switcherWidth).isActive = true
        let doc = FlippedView()
        doc.pin(list)
        // The pointer selects (its moves reach the monitor even though the panel never becomes key).
        doc.addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: doc))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay   // a legacy scroller would take the rows' right edge
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        let nine = 9 * (Metrics.rowTwoLine + Metrics.lineGap) + 2 * Metrics.gap
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Metrics.switcherWidth),
            scroll.heightAnchor.constraint(equalToConstant: min(list.fittingSize.height, nine, maxHeight))
        ])
        let column = NSStackView(views: [scroll])
        column.orientation = .vertical
        column.spacing = 0
        if let hint {
            let keys = NSTextField(labelWithString: hint)
            keys.font = .ui(TextSize.caption)
            keys.textColor = .tertiaryLabelColor
            column.addArrangedSubview(keys)
            column.edgeInsets.bottom = Metrics.gapWide
        }
        pin(column)
    }
    required init?(coder: NSCoder) { fatalError() }
}
