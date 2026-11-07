import AppKit
import DesignKit
import KelpKit
import UniformTypeIdentifiers
import WorkbenchKit

/// Under a code file, like Xcode's and BBEdit's: what kind of file it is, where the cursor is, and the indentation the
/// file uses (no encoding: Kelp opens UTF-8 only, so naming it would say nothing).
@MainActor
final class EditorStatusBar: NSView {
    private let place = NSTextField(labelWithString: "")
    /// "Wrap" while long lines wrap: a click turns it off.
    private let wrap = PointerButton()
    private var wrapping = false
    /// "Restricted" while the project isn't trusted to run its language server or formatter, as VS Code's Restricted Mode
    /// says: the banner that asked is long gone, this stays. A click offers Trust.
    private let restricted = PointerButton()
    private let row = NSStackView()
    var onTrust: (() -> Void)?
    /// How many problems the file has: a click lists those of every open file.
    private let problems = PointerButton()
    /// What the one under the cursor says.
    private let problem = NSTextField(labelWithString: "")
    var onProblems: (() -> Void)? { didSet { problems.onClick = onProblems } }
    var onWrap: (() -> Void)? { didSet { wrap.onClick = onWrap } }
    /// The indentation in use: a click offers another, or converts the file.
    private let indentButton = PointerButton()
    var indentMenu: (() -> NSMenu)?
    /// How the editor behaves, a right-click away; set by the tab that has an app to ask.
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    /// Off in a Markdown preview: there's no cursor to place, and how the source is indented or wrapped says nothing.
    var editing = true {
        didSet {
            place.isHidden = !editing
            indentButton.isHidden = !editing
            wrap.isHidden = !(editing && wrapping)
        }
    }

    init(url: URL, text: String) {
        super.init(frame: .zero)
        indentButton.font = .ui(11)
        indentButton.padding = Metrics.gap
        indentButton.onClick = { [weak self] in
            guard let self, let button = Optional(indentButton), let menu = indentMenu?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        }
        let kind = NSTextField(
            labelWithString: UTType(filenameExtension: url.pathExtension)?.localizedDescription
                ?? url.pathExtension.uppercased())
        for label in [kind, place] {
            label.font = .ui(11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        kind.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wrap.title = String(localized: "Wrap")
        wrap.font = .ui(11)
        wrap.padding = Metrics.gap
        wrap.isHidden = true
        wrap.toolTip = String(localized: "Long lines wrap (⌥Z)")
        restricted.title = String(localized: "Restricted")
        restricted.font = .ui(11)
        restricted.padding = Metrics.gap
        restricted.contentTintColor = .textOrange
        restricted.isHidden = true
        restricted.toolTip = String(
            localized: "Language servers and formatters don't run in this project until you trust it")
        restricted.onClick = { [weak self] in self?.offerTrust() }
        problems.font = .ui(11)
        problems.padding = Metrics.gap
        problems.isHidden = true
        problems.toolTip = String(localized: "Show Problems")
        problem.font = .ui(11)
        problem.textColor = .secondaryLabelColor
        problem.lineBreakMode = .byTruncatingTail
        problem.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        row.setViews([kind, place, problems, problem, NSView(), restricted, wrap, indentButton], in: .leading)
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        let line = NSBox()
        line.boxType = .separator
        pin(row)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.statusBar)),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(wrapping: Bool) {
        self.wrapping = wrapping
        wrap.isHidden = !(editing && wrapping)
    }

    func show(restricted on: Bool) { restricted.isHidden = !on }
    /// A Markdown file's Edit, Split, Preview, last in the bar.
    func show(modes: NSControl) {
        modes.controlSize = .mini
        modes.font = .ui(11)   // the bar's own size, as "Markdown" beside it
        row.addArrangedSubview(modes)
    }

    private func offerTrust() {
        let menu = NSMenu()
        menu.add(String(localized: "Trust This Project")) { [weak self] in self?.onTrust?() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: restricted.bounds.height + 2), in: restricted)
    }

    func show(indent: Indentation) {
        indentButton.title =
            switch indent {
            case .tabs: String(localized: "Tab Indentation")
            case .spaces(let width): String(localized: "Spaces: \(width)")
            }
    }

    func show(errors: Int, warnings: Int) {
        problems.isHidden = errors + warnings == 0
        problems.title = [errors > 0 ? "✕ \(errors)" : nil, warnings > 0 ? "⚠ \(warnings)" : nil].compactMap { $0 }
            .joined(separator: "  ")
        problems.contentTintColor = errors > 0 ? .textRed : .textOrange
    }

    func show(problem text: String?) { problem.stringValue = text ?? "" }

    func show(cursor: (line: Int, column: Int)?) {
        place.stringValue = cursor.map { String(localized: "Line \($0.line), Column \($0.column)") } ?? ""
    }
}

extension EditorStatusBar {
    /// How the editor behaves.
    static func menu(_ app: AppModel, language: String?) -> NSMenu {
        let menu = NSMenu()
        menu.add(String(localized: "Wrap Long Lines")) { app.extensions.run("editor.toggleWordWrap") }.state =
            app.settings.bool("editor.wordWrap", language: language) == true ? .on : .off
        menu.addToggle("editor.autoSave", app, title: String(localized: "Save Automatically"))
        menu.addToggle("editor.formatOnSave", app, title: String(localized: "Format on Save"))
        menu.addItem(.separator())
        menu.addSettingsLink(String(localized: "Editor Settings…"), section: "editor", app)
        return menu
    }
}
