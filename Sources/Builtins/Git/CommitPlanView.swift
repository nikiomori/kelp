import AppKit
import DesignKit
import KelpKit

/// The plan over the Commit button: who wrote it with Ask Again and Discard, then a card per commit, its message edited
/// in place as the Message field's is, its files named under it, ✕ to drop it (its files stay uncommitted).
@MainActor
final class CommitPlanView: NSStackView {
    var onEdit: ((Int, String) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onAskAgain: (() -> Void)?
    var onDiscard: (() -> Void)?
    /// ⌘↩ in a card: every commit of the plan.
    var onCommit: (() -> Void)?
    private let logo = NSImageView()
    private let title = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.gap
        title.font = .ui(TextSize.row)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logo.imageScaling = .scaleProportionallyDown
        logo.widthAnchor.constraint(equalToConstant: 14).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let again = IconButton(.symbol("arrow.clockwise"), tip: String(localized: "Ask Again")) { [weak self] in
            self?.onAskAgain?()
        }
        let discard = IconButton(.symbol("xmark"), tip: String(localized: "Discard Plan")) { [weak self] in
            self?.onDiscard?()
        }
        let head = NSStackView(views: [logo, title, NSView(), again, discard])
        head.spacing = Metrics.gap
        addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ plan: CommitPlan, logo image: NSImage?) {
        logo.image = image
        title.stringValue = String(localized: "\(plan.commits.count) commits by \(plan.agent)")
        for card in arrangedSubviews.dropFirst() { card.removeFromSuperview() }
        for (i, commit) in plan.commits.enumerated() {
            let card = PlanCard(number: i + 1, commit: commit)
            card.onEdit = { [weak self] in self?.onEdit?(i, $0) }
            card.onRemove = { [weak self] in self?.onRemove?(i) }
            card.onCommit = { [weak self] in self?.onCommit?() }
            addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
}

/// One commit of the plan: its number, its message to edit, its files.
@MainActor
private final class PlanCard: FieldBox {
    var onEdit: ((String) -> Void)?
    var onRemove: (() -> Void)?
    var onCommit: (() -> Void)?
    private let text = CommitTextView()
    private var height: NSLayoutConstraint?

    init(number: Int, commit: CommitPlan.Commit) {
        super.init(frame: .zero)
        wantsLayer = true
        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = .uiDigits(TextSize.caption, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.setContentHuggingPriority(.required, for: .horizontal)   // the message takes the width, not the number
        text.string = commit.message
        text.isRichText = false
        text.font = .ui(TextSize.body)
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 2, height: 6)
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        // Sized by the card's constraints, not by itself: no scroll view, the card grows with the message instead.
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.onCommit = { [weak self] in self?.onCommit?() }
        text.onChange = { [weak self] in
            guard let self else { return }
            self.onEdit?(self.text.string)
            self.fit()
        }
        let remove = IconButton(.symbol("xmark"), tip: String(localized: "Remove This Commit (its files stay)")) {
            [weak self] in self?.onRemove?()
        }
        remove.symbolConfiguration = .chrome(Metrics.iconTiny)
        let files = NSTextField(labelWithString: Self.files(commit.files))
        files.font = .ui(TextSize.caption)
        files.textColor = .secondaryLabelColor
        files.lineBreakMode = .byTruncatingTail
        files.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        files.toolTip = commit.files.joined(separator: "\n")
        for v in [badge, text, remove, files] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let h = text.heightAnchor.constraint(equalToConstant: 30)
        height = h
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gapWide),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            text.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: remove.leadingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 1), h,
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            files.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 7),
            files.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.gapWide),
            files.topAnchor.constraint(equalTo: text.bottomAnchor),
            files.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.gap)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "3 files: Package.swift, PRWork.swift, …": the names say more than a count in a panel this narrow.
    static func files(_ paths: [String]) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return paths.count == 1 ? names : String(localized: "\(paths.count) files: \(names)")
    }

    /// As tall as its message, up to eight lines: measured once the card has its width.
    override func layout() {
        super.layout()
        fit()
    }
    private func fit() {
        guard let lm = text.layoutManager, let tc = text.textContainer else { return }
        lm.ensureLayout(for: tc)
        let lines = lm.usedRect(for: tc).height + text.textContainerInset.height * 2
        let next = min(max(30, ceil(lines)), 8 * 17 + 12)
        if height?.constant != next { height?.constant = next }
    }
}
