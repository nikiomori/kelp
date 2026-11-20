import AppKit
import Core
import DesignKit
import KelpKit

/// The list's lines for pull requests and issues: a state glyph, the title on up to two lines, and under it the
/// number, who, how long ago, and what stands out (a conflict, a draft, the checks).
@MainActor
enum ForgeRows {
    /// The PRs in the order you act on them: the branch on screen, what waits for your review, yours, and the rest.
    /// There is a heading only where there's more than one part.
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

    static func heading(_ text: String) -> NSView { SectionHeading(text) }

    static func pr(_ pr: GitHub.PullRequest, worktree: Bool, unseen: Bool) -> ForgeRowCell {
        var said = [word("#\(pr.number)"), word(pr.author)]
        if let updated = pr.updatedAt.map(CIRunLook.ago), !updated.isEmpty { said.append(word(updated)) }
        if pr.isDraft {
            said.append(word(String(localized: "draft")))
        } else if pr.mergeState == "DIRTY" {
            said.append(word(String(localized: "conflict"), .textOrange))
        } else if pr.reviewDecision == "CHANGES_REQUESTED" {
            said.append(word(String(localized: "changes requested"), .textOrange))
        } else if pr.reviewDecision == "APPROVED" {
            said.append(word(String(localized: "approved")))
        }
        // The checks as drawn symbols: passed and running are quiet grey; only a failure has a colour.
        let checks = pr.checks, size = TextSize.caption
        if checks.failed > 0 {
            said.append(.signed("xmark.circle.fill", checks.failed, size: size, color: .textRed))
        } else if checks.pending > 0 {
            said.append(.signed("circle.dotted", nil, size: size, color: .secondaryLabelColor))
        } else if checks.passed > 0 {
            said.append(.signed("checkmark.circle.fill", nil, size: size, color: .secondaryLabelColor))
        }
        return ForgeRowCell(
            symbol: symbol(pr), tint: .pullRequest(state: pr.state, draft: pr.isDraft), title: pr.title,
            meta: joined(said), branch: worktree, unseen: unseen)
    }

    /// A merged and a closed pull request each have a shape of their own, so neither is told from an open one by its
    /// colour alone. A draft keeps the open one's, because its line says "draft".
    private static func symbol(_ pr: GitHub.PullRequest) -> String {
        switch pr.isDraft ? "DRAFT" : pr.state {
        case "MERGED": "arrow.triangle.merge"
        case "CLOSED": "xmark.circle"
        default: "arrow.triangle.pull"
        }
    }

    static func issue(_ issue: GitHub.Issue, working: Bool) -> ForgeRowCell {
        var parts = ["#\(issue.number)"]
        if let author = issue.author { parts.append(author) }
        if let updated = issue.updatedAt.map(CIRunLook.ago), !updated.isEmpty { parts.append(updated) }
        if !issue.labels.isEmpty { parts.append(issue.labels.joined(separator: ", ")) }
        if working { parts.append(String(localized: "in work")) }
        return ForgeRowCell(
            symbol: "smallcircle.filled.circle", tint: issue.state == "CLOSED" ? .textPurple : .textGreen,
            title: issue.title, meta: joined(parts.map { word($0) }), branch: working, unseen: false)
    }

    /// A part of the line in its colour, or with none for the caption's grey.
    private static func word(_ text: String, _ color: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: text, attributes: color.map { [.foregroundColor: $0] } ?? [:])
    }

    /// "#49 · ada · 3d · conflict": the parts with a dot between them.
    private static func joined(_ parts: [NSAttributedString]) -> NSAttributedString {
        let words = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { words.append(NSAttributedString(string: " · ")) }
            words.append(part)
        }
        return words
    }

    /// The row's height: a two-line row's 40, and a line more when the title takes two at `width`.
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
        return TextSize.of(Metrics.rowTwoLine) + (lines - 1) * line
    }
    private static let sizer: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .ui(TextSize.row)
        return field
    }()
    /// The room the title gives up beside it in a row: the glyph's column and the insets.
    static let titleMargin: CGFloat = 2 * Metrics.inset + Metrics.iconLarge + Metrics.gapWide + 12
}

/// One pull request or issue in the list.
@MainActor
final class ForgeRowCell: NSView {
    private let name: NSTextField

    /// A wrapping label wraps at the width it was last told, so it is told again once the row has its own width.
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
        name.font = .ui(TextSize.row, weight: unseen ? .semibold : .regular)
        name.maximumNumberOfLines = 2
        name.cell?.truncatesLastVisibleLine = true   // it wraps by word, and an ellipsis ends the second line
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
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        if unseen {
            // What changed since you last looked is news, which the title's weight says; the row's tooltip and
            // VoiceOver say it in words.
            toolTip = String(localized: "Changed since you last opened it")
            setAccessibilityHelp(toolTip)
        }
        // The lines stand in the middle of the row, as a tracker's task's do in the same list.
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
