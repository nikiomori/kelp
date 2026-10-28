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

    init(url: URL, text: String) {
        super.init(frame: .zero)
        let kind = NSTextField(labelWithString: UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? url.pathExtension.uppercased())
        let indent: String = switch Indentation.detect(text) {
        case .tabs?: String(localized: "Tab Indentation")
        case .spaces(let n)?: String(localized: "Spaces: \(n)")
        case nil: ""
        }
        let format = NSTextField(labelWithString: ["UTF-8", indent].filter { !$0.isEmpty }.joined(separator: "  ·  "))
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

    func show(cursor: (line: Int, column: Int)?) {
        place.stringValue = cursor.map { String(localized: "Line \($0.line), Column \($0.column)") } ?? ""
    }
}
