// The card over the agent strip: one agent's question, answered with Kelp left behind.
import AppKit
import Core
import DesignKit
import KelpKit

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
    /// The question it shows: Allow answers this one. Another asked meanwhile is the strip's to show in a new card.
    let question: String
    private let app: AppModel
    private let onEnd: (End) -> Void
    private var panel: StripPanel?
    private var arm: Task<Void, Never>?

    init(_ s: Session, app: AppModel, fullScreen: Bool, onEnd: @escaping (End) -> Void) {
        session = s.id
        question = s.summary
        self.app = app
        self.onEnd = onEnd
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        stack.addArrangedSubview(header(s))
        stack.addArrangedSubview(title(s))
        if s.status == .done { stack.addArrangedSubview(replyField()) }
        let foot = footer(s)
        stack.addArrangedSubview(foot)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.inset).isActive = true
        }
        panel = StripPanel.floating(stack, radius: Metrics.radiusXL, fullScreen: fullScreen)
    }

    private lazy var reply: NSTextField = {
        let field = NSTextField()
        field.placeholderString = String(localized: "Message to the agent")
        field.font = .ui(12)
        field.target = self
        field.action = #selector(send)
        return field
    }()

    private func replyField() -> NSView { reply }

    private func header(_ s: Session) -> NSView {
        let worktree = app.worktree(s.worktreeId),
            place = app.groupName(worktree) ?? app.projectName(worktree?.repoId) ?? ""
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
        let plain =
            s.status == .done
            ? String(localized: "Done")
            : s.status == .error ? String(localized: "Failed") : String(localized: "Needs your input")
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
        if s.asksPermission {
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
        Notifications.answer(app, session, action, question: question)
        onEnd(.answered)
    }

    /// As from a banner: sent with Kelp behind; refused (a half-typed line in its prompt), the agent is shown.
    @objc private func send() {
        let text = reply.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = session, app = app
        Task {
            if await app.call(SessionSend(id: id, text: text, enter: true)) == nil {
                NSApp.activate()
                app.workbench.focus(session: id)
            }
        }
        onEnd(.answered)
    }

    /// Over the strip, or under it at the top of a screen; lined up with the strip's corner.
    func show(by strip: NSRect, in area: NSRect?, at corner: StripCorner) {
        guard let shown = panel, let content = shown.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let left = corner.isLeft ? strip.minX : corner.isRight ? strip.maxX - size.width : strip.midX - size.width / 2
        let bottom = corner.isTop ? strip.minY - Metrics.gapWide - size.height : strip.maxY + Metrics.gapWide
        var frame = NSRect(x: left, y: bottom, width: size.width, height: size.height)
        if let area {
            frame.origin.x = min(max(frame.minX, area.minX + Metrics.gapWide), area.maxX - size.width - Metrics.gapWide)
        }
        shown.setFrame(frame.offsetBy(dx: 0, dy: Motion.reduced ? 0 : -8), display: false)
        shown.alphaValue = 0
        shown.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.appear)
            shown.animator().setFrame(frame, display: true)
            shown.animator().alphaValue = 1
        }
    }

    func close() {
        arm?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}
