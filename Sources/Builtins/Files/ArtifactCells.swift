import AppKit
import Core
import DesignKit
import KelpKit

/// The Artifacts panel's rows: a heading, or a page's kind, title (bold until opened), how many of its title there are,
/// a second line when there's news, and when it last changed, which turns into ↗ under the pointer for a page that
/// opens in the browser.
@MainActor
struct ArtifactCells {
    let panel: ArtifactsPanel
    private static let symbols = [
        "doc": "doc.text", "review": "checklist", "slides": "play.rectangle", "design": "square.grid.2x2",
        "dashboard": "chart.bar"
    ]

    func heading(_ text: String) -> NSView {
        let title = label(text.uppercased(), font: .ui(11, weight: .semibold), color: .tertiaryLabelColor)
        let row = NSStackView(views: [title, NSView()])
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.insetTrailing)
        return row
    }

    func item(_ item: ArtifactItem, earlier: Int) -> NSView {
        let icon = NSImageView(image: .symbol(Self.symbols[item.type] ?? "doc.richtext"))
        icon.symbolConfiguration = .chrome()
        icon.contentTintColor = .secondaryLabelColor
        let project = panel.app.projectName(panel.app.worktree(panel.app.workbench.workspaceId)?.repoId)
        let name = label(
            panel.title(item, project), font: .ui(12, weight: panel.isNew(item) ? .semibold : .regular))
        var title: [NSView] = [name]
        if earlier > 0 {
            let more = label("\(earlier + 1)", font: .uiDigits(11), color: .secondaryLabelColor)
            more.toolTip = String(localized: "\(earlier + 1) pages of this title: the latest opens")
            more.setContentCompressionResistancePriority(.required, for: .horizontal)
            title.append(more)
        }
        let top = NSStackView(views: title)
        top.spacing = Metrics.gap
        var lines: [NSView] = [top]
        if let note = panel.note(item) {
            lines.append(label(note.text, font: .ui(11), color: note.waits ? .textOrange : .secondaryLabelColor))
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = ArtifactCell(views: [icon, text, NSView()] + end(item))
        row.spacing = Metrics.gap + 2
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        icon.widthAnchor.constraint(equalToConstant: Metrics.iconPoint + 2).isActive = true
        row.onHover = { [weak panel, weak row] on in
            guard let panel, let row else { return }
            panel.hover(on ? item : nil, over: row)
        }
        return row
    }

    /// When it last changed, or a spinner while its agent writes it; ↗ in its place under the pointer for a web page.
    private func end(_ item: ArtifactItem) -> [NSView] {
        if panel.writing(item) {
            let ring = NSProgressIndicator()
            ring.style = .spinning
            ring.controlSize = .small
            ring.startAnimation(nil)
            ring.toolTip = String(localized: "The agent is writing it")
            return [ring]
        }
        let when = label(
            shortAgo(Date(timeIntervalSince1970: item.modified ?? item.created)), font: .uiDigits(11),
            color: .secondaryLabelColor)
        when.setContentCompressionResistancePriority(.required, for: .horizontal)
        guard item.url != nil else { return [when] }
        let out = NSImageView(image: .symbol("arrow.up.right"))
        out.symbolConfiguration = .chrome(Metrics.iconTiny)
        out.contentTintColor = .secondaryLabelColor
        out.toolTip = String(localized: "Opens in your browser")
        out.isHidden = true
        return [when, out]
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

/// A page's row: under the pointer its time gives way to ↗ (when it has one), and the panel hears of it for the card.
final class ArtifactCell: NSStackView, Hoverable {
    var onHover: (Bool) -> Void = { _ in }
    func setHover(_ on: Bool) {
        if let out = arrangedSubviews.last as? NSImageView, arrangedSubviews.count > 1 {
            out.isHidden = !on
            arrangedSubviews[arrangedSubviews.count - 2].isHidden = on
        }
        onHover(on)
    }
}
