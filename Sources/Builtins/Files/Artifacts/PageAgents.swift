import AppKit
import Core
import DesignKit
import KelpKit

/// The agents that work with a page now, as their hooks tell (`Session.page`): each one's logo with its state's mark,
/// and a click on it goes to its chat. Cards, rows, the Artifacts panel and a page's own bar show them. An agent
/// without hooks never shows here; the panel's "is writing" guess still covers the chat that made the page.
@MainActor
enum PageAgents {
    /// The chats working with the page `target` opens, or waiting for the user while on it.
    static func on(_ target: String, _ app: AppModel) -> [Session] {
        app.sessions.filter { $0.page?.target == target && ($0.status == .working || $0.status == .waiting) }
    }

    /// What the faces and the "is editing" lines follow: each chat's state and the page it is on.
    static func watched(_ app: AppModel) -> [String] {
        app.sessions.map { "\($0.id)\($0.status)\($0.page?.target ?? "")\($0.page?.doing.rawValue ?? "")" }
    }

    /// The pages any agent works with now.
    static func busy(_ app: AppModel) -> Set<String> {
        Set(app.sessions.filter { $0.status == .working || $0.status == .waiting }.compactMap(\.page?.target))
    }

    /// What they do, in words: "Claude is editing · Codex is reading", or "Claude asks you", which waits.
    static func line(_ sessions: [Session], _ app: AppModel) -> (text: String, waits: Bool)? {
        guard !sessions.isEmpty else { return nil }
        let parts = sessions.map { session -> String in
            let name = session.agent.map { app.catalog.name($0) } ?? session.title
            if session.status == .waiting { return String(localized: "\(name) asks you") }
            return switch session.page?.doing ?? .editing {
            case .editing: String(localized: "\(name) is editing")
            case .reading: String(localized: "\(name) is reading")
            case .answering: String(localized: "\(name) is answering")
            }
        }
        return (parts.joined(separator: " · "), sessions.contains { $0.status == .waiting })
    }
}

/// The faces of the agents on a page, side by side. Each is a button to its chat, with a tooltip saying who does what.
@MainActor
final class PageAgentsView: NSStackView {
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init(frame: .zero)
        spacing = Metrics.gapTight
        detachesHiddenViews = true
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// On a plate of the window's colour, so the logos read over a picture.
    var plated = false {
        didSet {
            wantsLayer = true
            needsDisplay = true
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = plated ? NSColor.windowBackgroundColor.cgColor : nil
        layer?.cornerRadius = Metrics.radiusSM
    }

    func show(_ sessions: [Session]) {
        setViews(sessions.prefix(3).map(face), in: .leading)
        isHidden = sessions.isEmpty
    }

    private func face(_ session: Session) -> NSView {
        let side = Metrics.iconMenu
        let logo = session.agent.flatMap { app.catalog.icon($0, size: side) } ?? .symbol("person.crop.circle")
        let app = self.app, id = session.id
        let button = PointerButton(image: logo) { app.workbench.focus(session: id) }
        button.isBordered = false
        button.imageScaling = .scaleProportionallyUpOrDown
        button.widthAnchor.constraint(equalToConstant: side).isActive = true
        button.heightAnchor.constraint(equalToConstant: side).isActive = true
        let what = PageAgents.line([session], app)?.text ?? ""
        button.toolTip = "\(what) · «\(session.title)». " + String(localized: "Click to go to the chat.")
        button.setAccessibilityLabel(String(localized: "\(what): go to the chat"))
        let mark = StatusMark(size: 8)
        mark.status = session.status
        mark.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
            mark.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
            mark.widthAnchor.constraint(equalToConstant: 8), mark.heightAnchor.constraint(equalToConstant: 8)
        ])
        return button
    }
}
