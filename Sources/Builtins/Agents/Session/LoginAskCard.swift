import AppKit
import Core
import DesignKit
import KelpKit

/// A card over the bottom of an agent's terminal while its row asks whether the agent may use the user's login on a
/// site (`kelp browser open --shared`, `AgentSites.question`): the question, where the answer is kept, Deny and Allow.
/// The row only says the question; this is where it is answered, as a database change is (`DatabaseAskCard`).
@MainActor
final class LoginAskCard: NSView {
    private let app: AppModel, session: String
    private let title = NSTextField(wrappingLabelWithString: "")

    init(app: AppModel, session: String) {
        self.app = app
        self.session = session
        super.init(frame: .zero)
        let mark = NSImageView(image: .symbol("person.crop.circle", String(localized: "Your login")))
        mark.symbolConfiguration = .chrome(Metrics.segmentPoint)   // as the database card's, beside the same title
        mark.contentTintColor = .textOrange
        title.font = .ui(TextSize.body, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(
            wrappingLabelWithString: String(
                localized:
                    "There it acts as you, with your login from Kelp’s browser. Settings › Browser keeps the site."))
        detail.font = .ui(TextSize.row)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        let deny = NSButton(title: String(localized: "Deny"), target: self, action: #selector(denied))
        let allow = NSButton(title: String(localized: "Allow"), target: self, action: #selector(allowed))
        for button in [deny, allow] { button.bezelStyle = .push }   // neither takes Return: the terminal does
        let head = NSStackView(views: [mark, title])
        head.spacing = Metrics.gap
        let buttons = NSStackView(views: [NSView(), deny, allow])
        buttons.spacing = Metrics.gapWide
        let stack = NSStackView(views: [head, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.gap
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset, right: Metrics.inset)
        for view in [head, detail, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Metrics.inset).isActive = true
        }
        pin(FloatingCard(stack))
        isHidden = true
        track(owner: self) { [app] in
            app.session(session).map { $0.asksPermission ? $0.summary : "" } ?? ""
        } changed: { [weak self] question in
            self?.show(question)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Comes in while the row asks for the user's login, and goes the way a row does once it is answered.
    func show(_ question: String) {
        guard AgentSites.asksLogin(question) else {
            if !isHidden, let superview { leaveGhost(in: superview) }
            isHidden = true
            return
        }
        title.stringValue = question
        guard isHidden else { return }
        isHidden = false
        comeIn()
    }

    @objc private func allowed() { answer("allow") }
    @objc private func denied() { answer("deny") }
    private func answer(_ action: String) {
        Notifications.answer(app, session, action, question: app.session(session)?.summary)
    }
}
