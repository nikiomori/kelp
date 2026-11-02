import AppKit
import Core
import DesignKit

/// A panel that takes clicks and a typed reply and leaves the active app active. It stays up with Kelp behind, on every Space, and
/// at a level under the Dock's.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static func floating(_ content: NSView, radius: CGFloat, fullScreen: Bool) -> StripPanel {
        let p = StripPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.apply(fullScreen: fullScreen)
        p.contentView = ground(content, radius: radius)
        return p
    }

    /// Off: it stays out of a full-screen app's Space (a talk, a film).
    func apply(fullScreen: Bool) {
        collectionBehavior = [.canJoinAllSpaces, fullScreen ? .fullScreenAuxiliary : .fullScreenNone, .stationary, .ignoresCycle]
    }

    /// Liquid Glass where there is, the popover card before.
    private static func ground(_ content: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        return FloatingCard(content, radius: radius)
    }
}

/// A workspace on the strip: its project's tile with its state in the corner, and in a pill what its agent asks.
final class StripButton: PointerControl {
    static let stripHeight: CGFloat = 40
    private static let height: CGFloat = 32, tile: CGFloat = 24, markInset: CGFloat = 2, wordsWidth: CGFloat = 240

    var onClick: (() -> Void)?
    var onMenu: (() -> NSMenu)?
    private let icon = NSImageView(), mark = StatusMark(size: 12), label = NSTextField(labelWithString: "")
    private let glow = EdgeGlow(radius: StripButton.height / 2, spread: 2, strength: 0.35)
    private var trailing: NSLayoutConstraint?
    private var anyApp: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Self.height / 2
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        for v in [glow, icon, label, mark] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        notch()
        let closed = trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        trailing = closed
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height), closed,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.tile), icon.heightAnchor.constraint(equalToConstant: Self.tile),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.gapWide),
            label.centerYAnchor.constraint(equalTo: centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.wordsWidth),
            mark.centerXAnchor.constraint(equalTo: icon.trailingAnchor, constant: -Self.markInset),
            mark.centerYAnchor.constraint(equalTo: icon.bottomAnchor, constant: -Self.markInset)
        ])
        pin(glow)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The mark sits in a bite out of the tile's corner, so it reads on the strip's own glass in any theme, with no disc of its own.
    private func notch() {
        icon.wantsLayer = true
        icon.imageScaling = .scaleProportionallyUpOrDown   // a project's own icon can be a 16-pt favicon
        let bite = CAShapeLayer(), side = Self.tile, around = Self.markInset + 6
        let square = CGRect(x: 0, y: 0, width: side, height: side), corner = Metrics.radiusSM
        let tile = CGPath(roundedRect: square, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let round = CGRect(x: side - Self.markInset - around, y: Self.markInset - around, width: 2 * around, height: 2 * around)
        let hole = CGPath(ellipseIn: round, transform: nil)
        bite.path = tile.subtracting(hole)
        icon.layer?.mask = bite
    }

    func update(_ item: StripItem, open: Bool, app: AppModel) {
        if let repo = item.repo { ProjectIcon.show(repo, in: icon, app: app) }
        let status: AgentStatus = switch item.cell {
        case .asks: .waiting
        case .failed: .error
        case .working: .working
        case .done: .done
        }
        mark.status = status
        // A clear icon keeps the tile's shape.
        effectiveAppearance.performAsCurrentDrawingAppearance { icon.layer?.backgroundColor = NSColor.fillHover.cgColor }
        label.isHidden = !open
        trailing?.isActive = false
        trailing = trailingAnchor.constraint(equalTo: open ? label.trailingAnchor : icon.trailingAnchor, constant: open ? 12 : 4)
        trailing?.isActive = true
        label.attributedStringValue = open ? words(item) : NSAttributedString()
        glow.show(open ? (item.cell == .asks ? .systemOrange : .systemRed) : nil, breathing: open && item.cell == .asks)
        restFill = open ? .fillHover : nil
        toolTip = "\(item.name): \(status.words)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([item.name, status.words, open ? item.words : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private func words(_ item: StripItem) -> NSAttributedString {
        // In the string itself: attributed text doesn't take the field's truncation, and would stop dead at a word.
        let cut = NSMutableParagraphStyle()
        cut.lineBreakMode = .byTruncatingTail
        func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: cut])
        }
        let t = NSMutableAttributedString(attributedString: text(item.name, .ui(12, weight: .medium), .labelColor))
        t.append(text("  " + StripModel.brief(item.words ?? ""), .ui(12), item.cell == .asks ? .textOrange : .textRed))
        guard item.count > 1 else { return t }
        t.append(text("  \(item.count)", .uiDigits(11), .secondaryLabelColor))
        return t
    }

    override func clicked() { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    /// Kelp is behind and stays there: the first click is the click, and the pointer answers with it inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        anyApp = retracked(anyApp, .activeAlways)
    }
}

/// A push button that takes the click that reaches it with Kelp behind.
private final class CardButton: NSButton {
    private var run: (() -> Void)?
    convenience init(_ title: String, _ run: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.run = run
        bezelStyle = .push
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { run?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Over the strip: one agent's question, answered from here with Kelp left behind, the way its banner answers.
@MainActor
final class StripCard {
    private static let width: CGFloat = 320
    /// A card can come up under a click meant for something else: Allow takes clicks only after this.
    static let armAfter: Duration = .milliseconds(600)

    /// How it was left: put off, answered, or just gone to Kelp.
    enum End { case later, answered, left }

    let session: String
    private let app: AppModel
    private let onEnd: (End) -> Void
    private var panel: StripPanel?
    private var arm: Task<Void, Never>?

    init(_ s: Session, app: AppModel, fullScreen: Bool, onEnd: @escaping (End) -> Void) {
        session = s.id
        self.app = app
        self.onEnd = onEnd
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        stack.edgeInsets = NSEdgeInsets(top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        stack.addArrangedSubview(header(s))
        stack.addArrangedSubview(title(s))
        if s.status == .done { stack.addArrangedSubview(replyField()) }
        let foot = footer(s)
        stack.addArrangedSubview(foot)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.inset).isActive = true }
        panel = StripPanel.floating(stack, radius: Metrics.radiusXL, fullScreen: fullScreen)
    }

    private lazy var reply: NSTextField = {
        let f = NSTextField()
        f.placeholderString = String(localized: "Message to the agent")
        f.font = .ui(12)
        f.target = self
        f.action = #selector(send)
        return f
    }()

    private func replyField() -> NSView { reply }

    private func header(_ s: Session) -> NSView {
        let w = app.worktree(s.worktreeId), place = app.groupName(w) ?? app.projectName(w?.repoId) ?? ""
        let icon = NSImageView(image: app.catalog.icon(s.agent, size: 16) ?? NSImage())
        let name = NSTextField(labelWithString: "\(app.catalog.displayName(s)) · \(place)")
        name.font = .ui(11)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let later = IconButton(.symbol("xmark"), tip: String(localized: "Later")) { [weak self] in self?.onEnd(.later) }
        let bar = NSStackView(views: [icon, name, NSView(), later])
        bar.spacing = Metrics.gap
        return bar
    }

    private func title(_ s: Session) -> NSView {
        let plain = s.status == .done ? String(localized: "Done") : s.status == .error ? String(localized: "Failed") : String(localized: "Needs your input")
        let text = NSTextField(wrappingLabelWithString: s.summary.isEmpty ? plain : s.summary)
        text.font = .ui(13, weight: .semibold)
        text.textColor = s.status == .error ? .textRed : .labelColor
        text.maximumNumberOfLines = 4
        text.lineBreakMode = .byTruncatingTail
        text.preferredMaxLayoutWidth = Self.width - 2 * Metrics.inset
        return text
    }

    private func footer(_ s: Session) -> NSView {
        let open = CardButton(String(localized: "Open in Kelp")) { [weak self] in self?.openInKelp() }
        var views: [NSView] = [open, NSView()]
        if Notifier.asksPermission(s) {
            let allow = CardButton(String(localized: "Allow")) { [weak self] in self?.answer("allow") }
            allow.keyEquivalent = ""
            allow.bezelColor = .controlAccentColor
            allow.isEnabled = false
            arm = Task { [weak allow] in
                do { try await Task.sleep(for: Self.armAfter) } catch { return }
                allow?.isEnabled = true
            }
            views += [CardButton(String(localized: "Deny")) { [weak self] in self?.answer("deny") }, allow]
        } else if s.status == .done {
            views.append(CardButton(String(localized: "Send")) { [weak self] in self?.send() })
        }
        let bar = NSStackView(views: views)
        bar.spacing = Metrics.gapWide
        return bar
    }

    private func openInKelp() {
        NSApp.activate()
        app.workbench.focus(session: session)
        onEnd(.left)
    }

    private func answer(_ action: String) {
        app.notifier?.answer(session, action, question: app.session(session)?.summary)
        onEnd(.answered)
    }

    /// As from a banner: sent with Kelp behind; refused (a half-typed line in its prompt), the agent is shown.
    @objc private func send() {
        let text = reply.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = session, app = app
        Task { if await app.call(SessionSend(id: id, text: text, enter: true)) == nil { NSApp.activate(); app.workbench.focus(session: id) } }
        onEnd(.answered)
    }

    func show(above strip: NSRect) {
        guard let p = panel, let content = p.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let frame = NSRect(x: strip.midX - size.width / 2, y: strip.maxY + Metrics.gapWide, width: size.width, height: size.height)
        p.setFrame(frame.offsetBy(dx: 0, dy: Motion.reduced ? 0 : -8), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = Motion.duration(Motion.appear)
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
    }

    func close() {
        arm?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}
