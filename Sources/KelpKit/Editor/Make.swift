import AppKit
import DesignKit

/// The pages an agent can be asked to make (Make, on the start page and in the "+" menu). Each starts the default agent
/// with a line that sends it to `kelp artifact guide`, for the user to finish with what to make.
enum Make {
    struct Kind: Sendable {
        let id: String, title: String, symbol: String, help: String
    }

    static let kinds = [
        Kind(id: "doc", title: String(localized: "Doc"), symbol: "doc.text", help: String(localized: "A page to read and keep")),
        Kind(id: "review", title: String(localized: "Review"), symbol: "checklist", help: String(localized: "Choices you answer on the page")),
        Kind(id: "slides", title: String(localized: "Slides"), symbol: "play.rectangle", help: String(localized: "A deck to present")),
        Kind(id: "design", title: String(localized: "Design"), symbol: "square.grid.2x2", help: String(localized: "Screens side by side")),
        Kind(id: "dashboard", title: String(localized: "Dashboard"), symbol: "chart.bar", help: String(localized: "Numbers at a glance"))
    ]

    /// What the agent gets; the user writes what it's about after it. In English: it's the agent's instruction.
    static func line(_ k: Kind) -> String { "Make a \(k.id) (kelp artifact guide \(k.id)): " }

    /// The kinds as menu items, after a "Make" heading unless they're its submenu: each starts `start` with its line.
    @MainActor static func addItems(to m: NSMenu, heading: Bool = true, start: @escaping @MainActor (String) -> Void) {
        if heading { m.addItem(.sectionHeader(title: String(localized: "Make"))) }
        for k in kinds {
            let i = m.add(k.title) { start(line(k)) }
            i.show(.symbol(k.symbol))
            i.toolTip = k.help
        }
    }
}

/// Make's choices for a built-in (Artifacts' empty state): the default agent starts in the focused pane with the line
/// typed in, for the user to finish, as from "+".
@MainActor package func makeMenu(_ app: AppModel) -> NSMenu {
    let m = NSMenu()
    Make.addItems(to: m) { line in
        guard let editor = app.workbench.editor else { NSSound.beep(); return }
        editor.newAgent(prompt: line, draft: true)
    }
    return m
}

/// Make on the start page, in the foot of the field it fills: a small grey chip per kind. Each only puts a line in the
/// field, so it weighs no more than the words it adds.
@MainActor
final class MakeChips: NSStackView {
    init(pick: @escaping (Make.Kind) -> Void) {
        super.init(frame: .zero)
        spacing = Metrics.gap
        let chips = Make.kinds.map { k in
            let b = PointerButton(title: k.title) { pick(k) }
            b.font = .ui(12); b.padding = Metrics.gap
            b.restFill = .fillRest; b.toolTip = k.help
            b.setAccessibilityLabel(String(localized: "Make a \(k.title)")); b.setAccessibilityHelp(k.help)
            return b
        }
        setViews(chips, in: .leading)
    }
    required init?(coder: NSCoder) { fatalError() }
}
