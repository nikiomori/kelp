// The card over the agent strip, where the user answers one agent's question while Kelp stays behind other apps.
import AppKit
import Core
import DesignKit
import KelpKit

/// A card over the strip that shows one agent's question, so the user can answer it while Kelp stays behind, as from
/// the agent's banner. It takes the keyboard as it opens (⏎ is Allow or Send, ⌘⌫ is Deny, a digit picks an answer,
/// ⎋ closes). It closes as a popover does, on a click anywhere else or a move to another Space.
@MainActor
final class StripCard {
    static let width: CGFloat = 320
    /// A card can come up under a click meant for something else, so Allow takes clicks only after this delay and fills
    /// in meanwhile.
    static let arming: TimeInterval = 0.6
    static var armAfter: Duration { .milliseconds(Int(arming * 1000)) }

    /// How the card was left: put off, answered, or just closed or left for Kelp.
    enum End { case later, answered, left }

    let session: String
    /// The question the card shows, which is the one Allow answers. If the agent asks another question meanwhile, the
    /// strip shows it in a new card.
    let question: String
    let app: AppModel
    let onEnd: (End) -> Void
    var arm: Task<Void, Never>?
    private var panel: StripPanel?
    private var watchers: [Any] = []
    private var spaces: NSObjectProtocol?

    lazy var reply: NSTextField = {
        let field = NSTextField()
        field.placeholderString = String(localized: "Message to the agent")
        field.font = .ui(TextSize.row)
        field.target = self
        field.action = #selector(send)
        return field
    }()

    /// `position` says which of the waiting questions this is, and out of how many, when more than one waits.
    init(
        _ s: Session, app: AppModel, fullScreen: Bool, position: (Int, Int)? = nil,
        onEnd: @escaping (End) -> Void
    ) {
        session = s.id
        question = s.summary
        self.app = app
        self.onEnd = onEnd
        let kind = StripCardKind.of(s)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gapWide
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        for part in [header(s, position: position)] + body(s, kind) + [footer(kind)] {
            stack.addArrangedSubview(part)
            part.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.inset).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        let made = StripPanel.floating(stack, radius: Metrics.radiusXL, fullScreen: fullScreen)
        made.takesKeys()
        made.onCancel = { [weak self] in self?.onEnd(.left) }
        panel = made
    }

    func openInKelp() {
        NSApp.activate()
        app.workbench.focus(session: session)
        onEnd(.left)
    }

    func answer(_ action: String) {
        Notifications.answer(app, session, action, question: question)
        onEnd(.answered)
    }

    /// Sends an answer the user picked in the question's menu. If the question is gone (answered in the terminal, or
    /// another question is on screen), Kelp shows the agent instead.
    func pick(_ label: String) {
        let id = session, app = app, asked = question
        Task {
            if await app.call(SessionChoose(id: id, answer: label, question: asked)) != true {
                NSApp.activate()
                app.workbench.focus(session: id)
            }
        }
        onEnd(.answered)
    }

    /// Sends the typed reply with Kelp left behind, as a banner does. If the agent refuses it (say, a half-typed line
    /// sits in its prompt), Kelp shows the agent instead.
    @objc func send() {
        say(reply.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func say(_ text: String) {
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

    /// Shows the card above the strip, or below it when the strip is at the top of a screen, lined up with the strip's
    /// corner.
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
        shown.slideIn(to: frame, by: CGVector(dx: 0, dy: Motion.reduced ? 0 : -8))
        // The card takes the keys now. Kelp stays behind, so the app in front is still in front once the card closes.
        shown.makeKey()
        if reply.superview != nil { shown.makeFirstResponder(reply) }
        watch()
    }

    /// A click in another app, or on another Space, closes the card, as it would close a popover. Clicks on the strip
    /// itself go to Kelp and aren't handled here.
    private func watch() {
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd(.left) }   // AppKit hands a monitor its events on the main thread
        }
        watchers = [outside].compactMap { $0 }
        spaces = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd(.left) }   // queue: .main
        }
    }

    func close() {
        arm?.cancel()
        watchers.forEach(NSEvent.removeMonitor)
        watchers = []
        if let spaces { NSWorkspace.shared.notificationCenter.removeObserver(spaces) }
        spaces = nil
        // The card fades out as the strip does, rather than vanishing at once.
        panel?.fadeOut()
        panel = nil
    }
}
