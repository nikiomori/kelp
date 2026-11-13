import AppKit
import Core
import DesignKit
import KelpKit

/// The list's lines for pull requests and issues: a state glyph, the title on up to two lines, and under it the number,
/// who, how long ago and what stands out (a conflict, a draft, the checks).
@MainActor
enum ForgeRows {
    /// The PRs in the order you act on them: the branch on screen, what waits for your review, yours, the rest.
    /// A heading only where there's more than one part.
    static func sections(_ prs: [GitHub.PullRequest], viewer: String?, branch: String?) -> [(
        String?, [GitHub.PullRequest]
    )] {
        var here: [GitHub.PullRequest] = [], review: [GitHub.PullRequest] = []
        var mine: [GitHub.PullRequest] = [], rest: [GitHub.PullRequest] = []
        for pr in prs {
            if pr.headRefName == branch {
                here.append(pr)
            } else if let viewer, pr.reviewRequests?.contains(viewer) == true {
                review.append(pr)
            } else if pr.author == viewer {
                mine.append(pr)
            } else {
                rest.append(pr)
            }
        }
        let parts: [(String, [GitHub.PullRequest])] = [
            (String(localized: "This Branch"), here), (String(localized: "Waiting for Your Review"), review),
            (String(localized: "Yours"), mine), (String(localized: "Others"), rest)
        ].filter { !$0.1.isEmpty }
        return parts.count == 1 ? [(nil, parts[0].1)] : parts.map { ($0.0, $0.1) }
    }

    static func heading(_ text: String) -> NSView {
        let title = NSTextField.label(
            text.uppercased(), font: .ui(TextSize.caption, weight: .semibold), color: .tertiaryLabelColor)
        let row = NSStackView(views: [title, NSView()])
        row.alignment = .bottom
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 4, right: Metrics.insetTrailing)
        return row
    }

    /// The glyph's colour, GitHub's: open green, draft grey, merged purple, closed red.
    static func color(state: String, draft: Bool = false) -> NSColor {
        if draft { return .secondaryLabelColor }
        switch state {
        case "MERGED": return .textPurple
        case "CLOSED": return .textRed
        default: return .textGreen
        }
    }

    static func pr(_ pr: GitHub.PullRequest, worktree: Bool, unseen: Bool) -> ForgeRowCell {
        var said: [(String, NSColor?)] = [("#\(pr.number)", nil), (pr.author, nil)]
        if let updated = pr.updatedAt.map(CIRunLook.ago), !updated.isEmpty { said.append((updated, nil)) }
        if pr.isDraft {
            said.append((String(localized: "draft"), nil))
        } else if pr.mergeState == "DIRTY" {
            said.append((String(localized: "conflict"), .textOrange))
        } else if pr.reviewDecision == "CHANGES_REQUESTED" {
            said.append((String(localized: "changes requested"), .textOrange))
        } else if pr.reviewDecision == "APPROVED" {
            said.append((String(localized: "approved"), nil))
        }
        let checks = pr.checks
        if checks.failed > 0 {
            said.append(("✕ \(checks.failed)", .textRed))
        } else if checks.pending > 0 {
            said.append(("◌", nil))
        } else if checks.passed > 0 {
            said.append(("✓", .textGreen))
        }
        return ForgeRowCell(
            symbol: "arrow.triangle.pull", tint: color(state: pr.state, draft: pr.isDraft), title: pr.title,
            meta: joined(said), branch: worktree, unseen: unseen)
    }

    static func issue(_ issue: GitHub.Issue, working: Bool) -> ForgeRowCell {
        var parts = ["#\(issue.number)"]
        if let author = issue.author { parts.append(author) }
        if let updated = issue.updatedAt.map(CIRunLook.ago), !updated.isEmpty { parts.append(updated) }
        if !issue.labels.isEmpty { parts.append(issue.labels.joined(separator: ", ")) }
        if working { parts.append(String(localized: "in work")) }
        return ForgeRowCell(
            symbol: "smallcircle.filled.circle", tint: issue.state == "CLOSED" ? .textPurple : .textGreen,
            title: issue.title, meta: joined(parts.map { ($0, nil) }), branch: working, unseen: false)
    }

    /// "#49 · ada · 3d · conflict": the parts with a dot between, each in its colour (none: the caption's grey).
    private static func joined(_ parts: [(String, NSColor?)]) -> NSAttributedString {
        let words = NSMutableAttributedString()
        for (index, (text, color)) in parts.enumerated() {
            if index > 0 { words.append(NSAttributedString(string: " · ")) }
            words.append(
                NSAttributedString(string: text, attributes: color.map { [.foregroundColor: $0] } ?? [:]))
        }
        return words
    }

    /// The title's lines at `width` (one or two), for the row's height.
    static func height(title: String, width: CGFloat) -> CGFloat {
        sizer.stringValue = title
        let line = TextSize.of(16)
        let lines = min(
            2,
            max(
                1,
                (sizer.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000))
                    .height ?? line) / line
            ).rounded())
        return TextSize.of(8 + 15) + lines * line + TextSize.of(4)
    }
    private static let sizer: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .ui(TextSize.row, weight: .medium)
        return field
    }()
    /// What the title has beside it in a row: the glyph's column and the insets.
    static let titleMargin: CGFloat = 2 * Metrics.inset + Metrics.iconLarge + Metrics.gapWide + 12
}

/// One pull request or issue in the list.
@MainActor
final class ForgeRowCell: NSView {
    private let name: NSTextField

    /// A wrapping label wraps at the width it was last told: told again once the row has its own.
    override func layout() {
        super.layout()
        guard abs(name.preferredMaxLayoutWidth - name.bounds.width) > 0.5 else { return }
        name.preferredMaxLayoutWidth = name.bounds.width
        super.layout()
    }

    init(symbol: String, tint: NSColor, title: String, meta: NSAttributedString, branch: Bool, unseen: Bool) {
        let icon = NSImageView(image: .symbol(symbol))
        icon.symbolConfiguration = .chrome(Metrics.iconLarge)
        icon.contentTintColor = tint
        name = NSTextField(wrappingLabelWithString: title)
        super.init(frame: .zero)
        name.font = .ui(TextSize.row, weight: unseen ? .semibold : .medium)
        name.maximumNumberOfLines = 2
        name.cell?.truncatesLastVisibleLine = true   // wraps by word, an ellipsis ends the second line
        name.isSelectable = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSMutableAttributedString(attributedString: meta)
        words.addAttributes(
            [.font: NSFont.ui(TextSize.caption)], range: NSRange(location: 0, length: words.length))
        words.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: words.length)) { value, range, _ in
            if value == nil { words.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range) }
        }
        let sub = NSTextField(labelWithAttributedString: words)
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var line: [NSView] = [sub]
        if branch {
            let mark = NSImageView(image: .symbol("arrow.triangle.branch"))
            mark.symbolConfiguration = .chrome(Metrics.iconSmall)
            mark.contentTintColor = .secondaryLabelColor
            mark.toolTip = String(localized: "Has a folder in Kelp")
            line.insert(mark, at: 0)
        }
        let under = NSStackView(views: line)
        under.spacing = 4
        let text = NSStackView(views: [name, under])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.lineGap
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = Metrics.gapWide
        row.edgeInsets = NSEdgeInsets(top: 6, left: Metrics.inset, bottom: 6, right: Metrics.inset)
        if unseen {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            dot.layer?.cornerRadius = Metrics.radiusXS
            dot.toolTip = String(localized: "Changed since you last opened it")
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)
            ])
            row.addArrangedSubview(dot)
        }
        pin(row)
    }
    required init?(coder: NSCoder) { fatalError() }
}
