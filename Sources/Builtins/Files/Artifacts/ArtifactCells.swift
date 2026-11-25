import AppKit
import Core
import DesignKit
import KelpKit

/// Builds the rows of the Artifacts panel. A row is a heading, or a page. A page's row shows its kind, its title (bold
/// until opened), Claude's mark when the page is on claude.ai, how many pages share the title, a second line when there
/// is news, and when it last changed. For a page that opens in the browser, the time turns into ↗ under the pointer.
@MainActor
struct ArtifactCells {
    let panel: ArtifactsPanel
    private static let symbols = [
        "doc": "doc.text", "review": "checklist", "slides": "play.rectangle", "design": "square.grid.2x2",
        "dashboard": "chart.bar", "proof": "checkmark.seal", "motion": "film"
    ]

    /// The symbol of a kind of page, as its row and its tab show it.
    static func symbol(_ kind: String) -> String { symbols[kind] ?? "doc.richtext" }

    func heading(_ text: String) -> NSView { SectionHeading(text) }

    func item(_ item: ArtifactItem, earlier: Int) -> NSView {
        let icon = NSImageView(image: .symbol(Self.symbol(item.type)))
        icon.symbolConfiguration = .chrome()
        icon.contentTintColor = .secondaryLabelColor
        let project = panel.app.projectName(panel.app.worktree(panel.app.workbench.workspaceId)?.repoId)
        let name = NSTextField.label(
            panel.title(item, project), font: .ui(TextSize.row, weight: panel.isNew(item) ? .semibold : .regular))
        var title: [NSView] = [name]
        if item.url != nil, let logo = panel.app.catalog.icon(Session.claudeAgent, size: Metrics.iconSmall) {
            // The page is on claude.ai, not a file here, so the name gets the mark of where it lives.
            let mark = NSImageView(image: logo)
            mark.toolTip = String(localized: "On claude.ai: opens in your browser")
            mark.setContentCompressionResistancePriority(.required, for: .horizontal)
            title.append(mark)
        }
        if earlier > 0 {
            let more = CountCapsule()
            more.text = "\(earlier + 1)"
            more.toolTip = String(localized: "\(earlier + 1) pages of this title: the latest opens")
            more.setContentCompressionResistancePriority(.required, for: .horizontal)
            title.append(more)
        }
        let top = NSStackView(views: title)
        top.spacing = Metrics.gap
        var lines: [NSView] = [top]
        if let note = panel.note(item) {
            lines.append(
                NSTextField.label(
                    note.text, font: .ui(TextSize.caption), color: note.waits ? .textOrange : .secondaryLabelColor))
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = ArtifactCell(views: [icon, text, NSView()] + end(item))
        row.spacing = Metrics.gap   // icon to its name
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        // As wide as the widest kind's symbol (chart.bar, 20 pt at 13), so each draws whole at its size, centred.
        icon.imageScaling = .scaleNone
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        row.onHover = { [weak panel, weak row] on in
            guard let panel, let row else { return }
            panel.hover(on ? item : nil, over: row)
        }
        return row
    }

    /// The end of a page's row: when the page last changed, or the agents' working ring while its agent writes it.
    /// For a web page, a hidden ↗ follows, which takes the time's place under the pointer.
    private func end(_ item: ArtifactItem) -> [NSView] {
        if panel.writing(item) {
            // The agents' working ring, still under Reduce Motion. It names its state itself ("Working"), and sets its own
            // tooltip each time it is drawn.
            let ring = StatusMark(size: 12)
            ring.status = .working
            return [ring]
        }
        let when = NSTextField.label(
            shortAgo(Date(timeIntervalSince1970: item.modified ?? item.created)), font: .uiDigits(TextSize.caption),
            color: .secondaryLabelColor)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)
        guard item.url != nil else { return [when] }
        let out = NSImageView(image: .symbol("arrow.up.forward.square"))   // the square arrow: opens outside Kelp
        out.symbolConfiguration = .chrome(Metrics.iconTiny)
        out.contentTintColor = .secondaryLabelColor
        out.toolTip = String(localized: "Opens in your browser")
        out.isHidden = true
        return [when, out]
    }

}

/// The row for a page. Under the pointer, the row's time is swapped for ↗ (when the row has one), and the row tells
/// the panel, which shows the page's card.
final class ArtifactCell: NSStackView, Hoverable {
    var onHover: (Bool) -> Void = { _ in }
    func setHover(_ on: Bool) {
        if let out = arrangedSubviews.last as? NSImageView, arrangedSubviews.count > 1 {
            if out.isHidden == on, window != nil { crossfade() }   // the time and ↗ fade into each other, as Stop does
            out.isHidden = !on
            arrangedSubviews[arrangedSubviews.count - 2].isHidden = on
        }
        onHover(on)
    }
}
