// The card over the agent strip: one agent's question, answered with Kelp left behind.
import AppKit
import Core
import DesignKit
import KelpKit

/// Over the strip: one agent's question, answered from here with Kelp left behind, the way its banner answers. It takes the
/// keyboard as it opens (⏎ Allow or Send, ⌘⌫ Deny, a digit picks an answer, ⎋ closes) and goes as a popover goes: on a
/// click anywhere else, or another Space.
@MainActor
final class StripCard {
    static let width: CGFloat = 320
    /// A card can come up under a click meant for something else: Allow takes clicks only after this, filling in meanwhile.
    static let arming: TimeInterval = 0.6
    static var armAfter: Duration { .milliseconds(Int(arming * 1000)) }

    /// How it was left: put off, answered, or just closed or gone to Kelp.
    enum End { case later, answered, left }

    let session: String
    /// The question it shows: Allow answers this one. Another asked meanwhile is the strip's to show in a new card.
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

    /// `position`: which of the questions waiting this is, and of how many, when there are more.
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

    /// One of its question's answers, picked in its menu; not there any more (answered in the terminal, another question
    /// on screen), the agent is shown.
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

    /// As from a banner: sent with Kelp behind; refused (a half-typed line in its prompt), the agent is shown.
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
        // Keys come here now; Kelp stays behind, so the app in front is still the one in front once it closes.
        shown.makeKey()
        if reply.superview != nil { shown.makeFirstResponder(reply) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.appear)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shown.animator().setFrame(frame, display: true)
            shown.animator().alphaValue = 1
        }
        watch()
    }

    /// A click in another app, or another Space: it goes, as a popover would. The strip's own clicks are Kelp's, not here.
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
        // It goes as the strip does: faded, not cut.
        if let shown = panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.duration(Motion.fast)
                shown.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { shown.orderOut(nil) }   // AppKit runs it on the main thread
            }
        }
        panel = nil
    }
}
