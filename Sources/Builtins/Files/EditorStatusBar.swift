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
    private let indent: String
    /// How the editor behaves, a right-click away; set by the tab that has an app to ask.
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    /// Off in a Markdown preview: there's no cursor to place, and how the source is indented says nothing.
    var editing = true {
        didSet { place.isHidden = !editing; layoutFormat() }
    }

    init(url: URL, text: String) {
        indent = switch Indentation.detect(text) {
        case .tabs?: String(localized: "Tab Indentation")
        case .spaces(let n)?: String(localized: "Spaces: \(n)")
        case nil: ""
        }
        super.init(frame: .zero)
        layoutFormat()
        let kind = NSTextField(labelWithString: UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? url.pathExtension.uppercased())
        for l in [kind, place, format] {
            l.font = .ui(11)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
        }
        kind.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [kind, place, NSView(), format]); row.spacing = 16
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
        format.stringValue = ["UTF-8", editing ? indent : ""].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    func show(cursor: (line: Int, column: Int)?) {
        place.stringValue = cursor.map { String(localized: "Line \($0.line), Column \($0.column)") } ?? ""
    }
}

extension EditorStatusBar {
    /// How the editor behaves.
    static func menu(_ app: AppModel) -> NSMenu {
        let m = NSMenu()
        m.addToggle("editor.wordWrap", app, title: String(localized: "Wrap Long Lines"))
        m.addToggle("editor.autoSave", app, title: String(localized: "Save Automatically"))
        m.addToggle("editor.formatOnSave", app, title: String(localized: "Format on Save"))
        m.addItem(.separator())
        m.addSettingsLink(String(localized: "Editor Settings…"), section: "editor", app)
        return m
    }
}
