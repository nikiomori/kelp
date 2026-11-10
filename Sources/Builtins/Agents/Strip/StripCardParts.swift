// What a card over the agent strip is made of: its head, what it asks, and the answers under it.
import AppKit
import Core
import DesignKit
import KelpKit

/// A push button that takes the click that reaches it with Kelp behind.
final class CardButton: NSButton {
    private var run: (() -> Void)?
    convenience init(
        _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], _ run: @escaping () -> Void
    ) {
        self.init(frame: .zero)
        self.title = title
        self.run = run
        bezelStyle = .push
        keyEquivalent = key
        keyEquivalentModifierMask = modifiers
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { run?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Words that act (Later, Open in Kelp): quiet beside the answers, and they too take the first click with Kelp behind.
private final class CardLink: PointerButton {
    convenience init(_ title: String, _ run: @escaping () -> Void) {
        self.init(title: title, action: run)
        font = .ui(TextSize.row)
        contentTintColor = .secondaryLabelColor
        padding = Metrics.gap / 2
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension StripCard {
    /// Its project, which agent, which of the waiting questions this is, and ✕, which only closes: a click on the tile
    /// brings it back.
    func header(_ s: Session, position: (Int, Int)?) -> NSView {
        let worktree = app.worktree(s.worktreeId)
        let place = app.groupName(worktree) ?? app.projectName(worktree?.repoId) ?? ""
        let icon = NSImageView()
        icon.wantsLayer = true
        icon.layer?.cornerRadius = Metrics.radiusXS
        icon.layer?.masksToBounds = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        if let repo = app.repo(worktree?.repoId)?.path { ProjectIcon.show(repo, in: icon, app: app) }
        icon.widthAnchor.constraint(equalToConstant: Metrics.appIcon).isActive = true
        icon.heightAnchor.constraint(equalToConstant: Metrics.appIcon).isActive = true
        let name = NSMutableAttributedString(
            string: place,
            attributes: [.font: NSFont.ui(TextSize.caption, weight: .medium), .foregroundColor: NSColor.labelColor])
        name.append(
            NSAttributedString(
                string: " · " + app.catalog.displayName(s),
                attributes: [.font: NSFont.ui(TextSize.caption), .foregroundColor: NSColor.secondaryLabelColor]))
        let label = NSTextField(labelWithAttributedString: name)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, label, NSView()]
        if let (index, count) = position {
            let of = NSTextField(labelWithString: String(localized: "\(index) of \(count)"))
            of.font = .uiDigits(TextSize.caption)
            of.textColor = .secondaryLabelColor
            views.append(of)
        }
        views.append(
            IconButton(.symbol("xmark"), tip: String(localized: "Close")) { [weak self] in self?.onEnd(.left) })
        let bar = NSStackView(views: views)
        bar.spacing = Metrics.gap
        return bar
    }

    /// What it asks: a permission's kind over the whole of what it would do; a question with its answers; or what it said.
    func body(_ s: Session, _ kind: StripCardKind) -> [NSView] {
        switch kind {
        case .permission:
            let (title, detail) = StripModel.permission(s.summary)
            return [heading(title, red: false)] + (detail.map { [code($0)] } ?? [])
        case .choices(let labels):
            return [heading(s.summary, red: false), answers(labels)]
        case .reply, .look:
            let plain =
                s.status == .done
                ? String(localized: "Done")
                : s.status == .error ? String(localized: "Failed") : String(localized: "Needs your input")
            let said = heading(s.summary.isEmpty ? plain : s.summary, red: s.status == .error)
            return kind == .reply ? [said, reply] : [said]
        }
    }

    private func heading(_ text: String, red: Bool) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .ui(TextSize.body, weight: .semibold)
        label.textColor = red ? .textRed : .labelColor
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset
        return label
    }

    /// The whole command or path, in the code font, wrapped: what Allow allows, with nothing left out.
    private func code(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .uiMono(TextSize.caption)
        label.maximumNumberOfLines = 8
        label.lineBreakMode = .byCharWrapping
        let inner = Self.width - 2 * Metrics.inset - 2 * Metrics.gapWide
        label.preferredMaxLayoutWidth = inner
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = Metrics.radiusSM
        box.layer?.cornerCurve = .continuous
        box.effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = NSColor.fillRest.cgColor
        }
        box.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Metrics.gapWide),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Metrics.gapWide),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: Metrics.gap),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Metrics.gap)
        ])
        return box
    }

    /// A button an answer, its number its key; side by side while three fit, else one under another.
    private func answers(_ labels: [String]) -> NSView {
        let buttons = labels.enumerated().map { i, label in
            CardButton(label, key: i < 9 ? "\(i + 1)" : "") { [weak self] in self?.pick(label) }
        }
        let stack = NSStackView(views: buttons)
        let wide = labels.count > 3 || labels.joined().count > 30
        stack.orientation = wide ? .vertical : .horizontal
        stack.alignment = wide ? .leading : .centerY
        stack.spacing = wide ? Metrics.lineGap : Metrics.gap
        return stack
    }

    /// Later and Open in Kelp quiet on the left, the answers on the right: Deny and Allow (filling in as it arms), the
    /// quick replies and Send.
    func footer(_ kind: StripCardKind) -> NSView {
        var views: [NSView] = [
            CardLink(String(localized: "Later")) { [weak self] in self?.onEnd(.later) },
            CardLink(String(localized: "Open in Kelp")) { [weak self] in self?.openInKelp() }, NSView()
        ]
        switch kind {
        case .permission:
            views += [
                CardButton(String(localized: "Deny"), key: "\u{8}", modifiers: .command) { [weak self] in
                    self?.answer("deny")
                },
                allowButton()
            ]
        case .reply:
            let goOn = QuickReply.goOn
            views.append(CardButton(goOn.title) { [weak self] in self?.say(goOn.text) })
            let send = CardButton(String(localized: "Send"), key: "\r") { [weak self] in self?.send() }
            send.bezelColor = .controlAccentColor
            views.append(send)
        case .choices, .look: break
        }
        let bar = NSStackView(views: views)
        bar.spacing = Metrics.gap
        return bar
    }

    /// Takes clicks once it has filled in: a card that came up under a click meant for something else can't be allowed by it.
    private func allowButton() -> NSButton {
        let allow = CardButton(String(localized: "Allow"), key: "\r") { [weak self] in self?.answer("allow") }
        allow.bezelColor = .controlAccentColor
        allow.isEnabled = false
        allow.alphaValue = Metrics.paneDim
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Self.arming)
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            allow.animator().alphaValue = 1
        }
        arm = Task { [weak allow] in
            do { try await Task.sleep(for: Self.armAfter) } catch { return }
            allow?.alphaValue = 1
            allow?.isEnabled = true
        }
        return allow
    }
}
