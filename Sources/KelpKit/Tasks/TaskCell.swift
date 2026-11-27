import AppKit
import Core
import DesignKit

/// One task in a list (the Tasks tab, the Issues panel's Tasks source): the box, which is the person's (done, or given
/// up with ⌥), the words on two lines' worth of row with where the line is under them, and on the right what an agent
/// does with it: its logo with the chat's mark, as the sidebar draws the chat, and a word. Under the pointer a line no
/// agent works on offers ▶ (do it with the last agent) and ⋯ (its menu).
@MainActor
package final class TaskCell: NSView {
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = NSTextField.label("", font: .ui(TextSize.row))
    private let line = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private let face = NSImageView()
    private let mark = StatusMark(size: Metrics.iconSmall)
    private let word = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    private let run = IconButton(.symbol("play.fill"), tip: "") {}
    private let more = IconButton(.symbol("ellipsis"), tip: String(localized: "More Actions")) {}
    private var hovering = false { didSet { showButtons() } }
    private var offersRun = false
    package var onToggle: (_ cancel: Bool) -> Void = { _ in }
    package var onRun: () -> Void = {}
    package var onMenu: (NSView) -> Void = { _ in }

    package init() {
        super.init(frame: .zero)
        box.target = self
        box.action = #selector(boxed)
        box.allowsMixedState = true
        // One line each, cut with an ellipsis: a narrow board card keeps its words over their place.
        for label in [name, line] {
            label.cell?.wraps = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        for label in [name, line, word] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        word.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        face.imageScaling = .scaleProportionallyUpOrDown
        run.target = self
        run.action = #selector(runClicked)
        more.target = self
        more.action = #selector(moreClicked)
        let words = NSStackView(views: [name, line])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Metrics.lineGap
        let work = NSStackView(views: [face, mark, word, run, more])
        work.spacing = Metrics.gapTight
        work.detachesHiddenViews = true
        let row = NSStackView(views: [box, words, NSView(), work])
        row.spacing = Metrics.gap
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.insetTrailing)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        pin(row)
        NSLayoutConstraint.activate([
            face.widthAnchor.constraint(equalToConstant: Metrics.iconSmall),
            face.heightAnchor.constraint(equalToConstant: Metrics.iconSmall)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A cell showing `row` with `place` under its words, wired as every list has it: the box, ▶ with the last agent,
    /// and ⋯, whose menu `fill` fills (with the task's own actions when nil).
    package convenience init(_ app: AppModel, _ row: TaskRow, place: String, fill: ((NSMenu) -> Void)? = nil) {
        self.init()
        show(
            row, chats: (row.task.chats ?? []).compactMap(app.session), place: place,
            agent: app.catalog.name(TaskActions.lastAgent(app)),
            icon: { app.catalog.icon($0, size: Metrics.iconSmall) })
        onToggle = { cancel in cancel ? TaskActions.set(app, row, .cancelled) : TaskActions.toggle(app, row) }
        onRun = { TaskActions.run(app, row) }
        onMenu = { view in
            let menu = NSMenu()
            if let fill { fill(menu) } else { TaskActions.fill(menu, app, row) }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
    }

    /// Shows `row`, whose chats are `chats`, with `place` under the words (where the line is, its issue, its tags) and
    /// `agent`'s name on ▶.
    private func show(_ row: TaskRow, chats: [Session], place: String, agent: String, icon: (String?) -> NSImage?) {
        let task = row.task
        box.state = task.state == .done ? .on : task.state == .cancelled ? .mixed : .off
        box.alphaValue = task.proposed == true ? Metrics.unavailable : 1
        box.toolTip =
            task.proposed == true
            ? String(localized: "Take the agent’s proposal") : String(localized: "Done (⌥: cancel)")
        let color: NSColor = task.state == .open ? .labelColor : .tertiaryLabelColor
        let cut = NSMutableParagraphStyle()
        cut.lineBreakMode = .byTruncatingTail   // the words' own style wins over the field's
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color, .font: NSFont.ui(TextSize.row), .paragraphStyle: cut
        ]
        if task.state == .cancelled { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        name.attributedStringValue = NSAttributedString(string: task.title, attributes: attributes)
        line.stringValue = place
        // The chat that matters most: one that asks, then fails, then works; the newest otherwise.
        let chat = chats.max { TaskWork.of([$0]) < TaskWork.of([$1]) } ?? chats.last
        face.image = chat.flatMap { icon($0.agent) }
        face.isHidden = face.image == nil
        mark.status = chat?.status
        if let chat { mark.follow(chat) }
        mark.isHidden = chat == nil
        word.stringValue = Self.word(row, chat)
        word.textColor = row.work == .asks || row.task.proposed == true ? .textOrange : .secondaryLabelColor
        word.isHidden = word.stringValue.isEmpty
        offersRun = task.state == .open && task.proposed != true && (row.work == .none || row.work == .review)
        run.toolTip = String(localized: "Do with \(agent)")
        showButtons()
        setAccessibilityLabel([task.title, place, word.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// The word beside the mark: what the person would want to know of the work.
    package static func word(_ row: TaskRow, _ chat: Session?) -> String {
        if row.task.proposed == true { return String(localized: "Proposed") }
        switch row.work {
        case .asks: return String(localized: "Asks you")
        case .failed: return String(localized: "Failed")
        case .working: return chat?.status == .paused ? String(localized: "Paused") : String(localized: "Working")
        case .review: return row.task.state == .open ? String(localized: "To Review") : ""
        case .none: return ""
        }
    }

    private func showButtons() {
        run.isHidden = !(hovering && offersRun)
        more.isHidden = !hovering
    }

    @objc private func boxed() {
        let cancel = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        onToggle(cancel)
    }
    @objc private func runClicked() { onRun() }
    @objc private func moreClicked() { onMenu(more) }

    override package func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override package func mouseEntered(with event: NSEvent) { hovering = true }
    override package func mouseExited(with event: NSEvent) { hovering = false }
}
