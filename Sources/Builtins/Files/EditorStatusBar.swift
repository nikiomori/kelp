import AppKit
import DesignKit
import UniformTypeIdentifiers
import WorkbenchKit
import KelpKit

/// Under a code file, like Xcode's and BBEdit's: what kind of file it is, where the cursor is, the encoding and the
/// indentation the file uses.
@MainActor
final class EditorStatusBar: NSView {
    private let place = NSTextField(labelWithString: "")
    private let format = NSTextField(labelWithString: "")
    /// "Wrap" while long lines wrap: a click turns it off.
    private let wrap = PointerButton()
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
    /// Off in a Markdown preview: there's no cursor to place, and how the source is indented says nothing.
    var editing = true {
        didSet {
            place.isHidden = !editing
            indentButton.isHidden = !editing
        }
    }

    init(url: URL, text: String) {
        super.init(frame: .zero)
        indentButton.font = .ui(11)
        indentButton.padding = Metrics.gap
        indentButton.onClick = { [weak self] in
            guard let self, let b = Optional(indentButton), let m = indentMenu?() else { return }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 2), in: b)
        }
        layoutFormat()
        let kind = NSTextField(labelWithString: UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? url.pathExtension.uppercased())
        for l in [kind, place, format] {
            l.font = .ui(11)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
        }
        kind.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wrap.title = String(localized: "Wrap")
        wrap.font = .ui(11)
        wrap.padding = Metrics.gap
        wrap.isHidden = true
        wrap.toolTip = String(localized: "Long lines wrap (⌥Z)")
        problems.font = .ui(11)
        problems.padding = Metrics.gap
        problems.isHidden = true
        problems.toolTip = String(localized: "Show Problems")
        problem.font = .ui(11)
        problem.textColor = .secondaryLabelColor
        problem.lineBreakMode = .byTruncatingTail
        problem.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let row = NSStackView(views: [kind, place, problems, problem, NSView(), wrap, indentButton, format]); row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        let line = NSBox(); line.boxType = .separator
        pin(row)
        line.translatesAutoresizingMaskIntoConstraints = false; addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.statusBar)),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layoutFormat() {
        format.stringValue = "UTF-8"
    }

    func show(wrapping: Bool) { wrap.isHidden = !wrapping }

    func show(indent: Indentation) {
        indentButton.title = switch indent {
        case .tabs: String(localized: "Tab Indentation")
        case .spaces(let n): String(localized: "Spaces: \(n)")
        }
    }

    func show(errors: Int, warnings: Int) {
        problems.isHidden = errors + warnings == 0
        problems.title = [errors > 0 ? "✕ \(errors)" : nil, warnings > 0 ? "⚠ \(warnings)" : nil].compactMap { $0 }.joined(separator: "  ")
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
        let m = NSMenu()
        m.add(String(localized: "Wrap Long Lines")) { app.extensions.run("editor.toggleWordWrap") }.state =
            app.settings.bool("editor.wordWrap", language: language) == true ? .on : .off
        m.addToggle("editor.autoSave", app, title: String(localized: "Save Automatically"))
        m.addToggle("editor.formatOnSave", app, title: String(localized: "Format on Save"))
        m.addItem(.separator())
        m.addSettingsLink(String(localized: "Editor Settings…"), section: "editor", app)
        return m
    }
}
