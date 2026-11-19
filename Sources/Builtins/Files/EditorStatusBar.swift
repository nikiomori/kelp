import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// The bar under a code file, like Xcode's and BBEdit's: what kind of file it is, where the cursor is, and the
/// indentation the file uses. It shows no encoding: Kelp opens UTF-8 only, so naming it would say nothing.
@MainActor
final class EditorStatusBar: NSView {
    private let place = NSTextField(labelWithString: "")
    /// "Wrap" while long lines wrap: a click turns it off.
    private let wrap = PointerButton()
    private var wrapping = false
    /// Reads "Restricted", as VS Code's Restricted Mode does, while the project isn't trusted to run its language
    /// server or formatter. The banner that asked about trust is long gone by then, but this label stays. A click
    /// offers Trust.
    private let restricted = PointerButton()
    /// Names the file's language servers, or says that none is installed. A click lists each server, with Restart and
    /// Install.
    private let servers = PointerButton()
    var onServers: ((NSView) -> Void)?
    /// Names the model that suggests code, or that suggestions are off or have no model (Suggestions). A click opens
    /// what it does today, or how to turn it on.
    private let suggestions = PointerButton()
    var onSuggestions: ((NSView) -> Void)?
    private let row = NSStackView()
    var onTrust: (() -> Void)?
    /// Shows how many problems the file has. A click lists the problems of every open file.
    private let problems = PointerButton()
    /// The message of the problem under the cursor.
    private let problem = NSTextField.label("", font: .ui(TextSize.caption), color: .secondaryLabelColor)
    var onProblems: (() -> Void)? { didSet { problems.onClick = onProblems } }
    var onWrap: (() -> Void)? { didSet { wrap.onClick = onWrap } }
    /// The Wrap chip's tooltip, with Word Wrap's key. The file's tab sets it, because the tab has the app to ask.
    var wrapTip: String? { didSet { wrap.toolTip = wrapTip } }
    /// Shows the indentation in use. A click offers another one, or converts the file.
    private let indentButton = PointerButton()
    var indentMenu: (() -> NSMenu)?
    /// The right-click menu of editor options. The file's tab sets it, because the tab has the app to ask.
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    /// False in a Markdown preview, because there's no cursor to place, and how the source is indented or wrapped
    /// doesn't matter there.
    var editing = true {
        didSet {
            place.isHidden = !editing
            indentButton.isHidden = !editing
            wrap.isHidden = !(editing && wrapping)
        }
    }

    init(url: URL, text: String) {
        super.init(frame: .zero)
        for button in [indentButton, wrap, restricted, servers, suggestions, problems] {
            button.font = .ui(TextSize.caption)
            button.padding = Metrics.gap
        }
        indentButton.onClick = { [weak self] in
            guard let self, let button = Optional(indentButton), let menu = indentMenu?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        let kind = NSTextField(
            labelWithString: UTType(filenameExtension: url.pathExtension)?.localizedDescription
                ?? url.pathExtension.uppercased())
        for label in [kind, place] {
            label.font = .ui(TextSize.caption)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        place.font = .uiDigits(TextSize.caption)   // the line and column change as the caret moves: the row stays still
        kind.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wrap.title = String(localized: "Wrap")
        wrap.isHidden = true
        restricted.title = String(localized: "Restricted")
        restricted.contentTintColor = .textOrange
        restricted.isHidden = true
        restricted.toolTip = String(
            localized: "Language servers and formatters don’t run in this project until you trust it")
        restricted.onClick = { [weak self] in self?.offerTrust() }
        servers.isHidden = true
        servers.onClick = { [weak self] in self.map { $0.onServers?($0.servers) } }
        suggestions.isHidden = true
        suggestions.onClick = { [weak self] in self.map { $0.onSuggestions?($0.suggestions) } }
        problems.isHidden = true
        problems.toolTip = String(localized: "Show Problems")
        problem.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        row.setViews(
            [kind, place, problems, problem, NSView(), restricted, servers, suggestions, wrap, indentButton],
            in: .leading)
        // The buttons' words have `padding` round them for the hover fill, so the gaps and the right edge take it off:
        // a button's word stands 8 pt from a label, as labels from each other, and the last word 12 pt from the edge.
        row.spacing = Metrics.gapWide - Metrics.gap
        row.setCustomSpacing(Metrics.gapWide, after: kind)
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset - Metrics.gap)
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
    func show(servers summary: ServerSummary?) {
        servers.isHidden = summary == nil
        servers.title = summary?.title ?? ""
        // Grey: "No Language Server" offers an install, and nothing waits on it (orange is for what waits on you).
        // Red when a server stopped, which the click's list restarts.
        let stopped = summary?.stopped ?? []
        servers.contentTintColor =
            !stopped.isEmpty ? .textRed : summary?.missing == true ? .secondaryLabelColor : nil
        servers.toolTip =
            stopped.isEmpty
            ? nil
            : String(
                localized: "\(stopped.joined(separator: ", ")) stopped. Click to see the servers, then Restart.")
    }
    func show(suggestions status: SuggestionStatus?) {
        suggestions.isHidden = status == nil
        suggestions.title = status?.text ?? ""
        suggestions.contentTintColor = status?.needsYou == true ? .textOrange : nil
    }
    /// Adds a Markdown file's Edit / Split / Preview control, last in the bar.
    func show(modes: NSControl) {
        modes.controlSize = .mini
        modes.font = .ui(TextSize.caption)   // the bar's own text size, like "Markdown" beside it
        row.addArrangedSubview(modes)
        row.edgeInsets.right = Metrics.inset   // it has no padding of its own

    }

    private func offerTrust() {
        let menu = NSMenu()
        menu.add(String(localized: "Trust This Project")) { [weak self] in self?.onTrust?() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: restricted.bounds.height + 4), in: restricted)
    }

    func show(indent: Indentation) {
        indentButton.title =
            switch indent {
            case .tabs: String(localized: "Tab Indentation")
            case .spaces(let width): String(localized: "Spaces: \(width)")
            }
    }

    /// The count in two parts, each with its own symbol and colour, so warnings stay orange beside red errors.
    func show(errors: Int, warnings: Int) {
        problems.isHidden = errors + warnings == 0
        problems.attributedTitle = Self.problemCount(errors: errors, warnings: warnings)
        problems.setAccessibilityLabel(String(localized: "Errors: \(errors), Warnings: \(warnings)"))
    }

    static func problemCount(errors: Int, warnings: Int) -> NSAttributedString {
        let font = NSFont.uiDigits(TextSize.caption), out = NSMutableAttributedString()
        let parts = [(errors, "xmark.circle", NSColor.textRed), (warnings, "exclamationmark.triangle", .textOrange)]
        for (count, name, color) in parts where count > 0 {
            if out.length > 0 {
                out.addAttribute(.kern, value: Metrics.gap, range: NSRange(location: out.length - 1, length: 1))
            }
            let part = NSMutableAttributedString()
            if let symbol = NSImage.symbol(name).withSymbolConfiguration(.chrome(Metrics.iconSmall)) {
                let sign = NSTextAttachment()
                sign.image = symbol
                // On the digits' middle: an attachment stands on the baseline otherwise.
                sign.bounds = NSRect(
                    origin: NSPoint(x: 0, y: (font.capHeight - symbol.size.height) / 2), size: symbol.size)
                part.append(NSAttributedString(attachment: sign))
                part.addAttribute(.kern, value: Metrics.iconGap, range: NSRange(location: 0, length: 1))
            }
            part.append(NSAttributedString(string: "\(count)"))
            part.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: part.length))
            out.append(part)
        }
        return out
    }

    func show(problem text: String?) { problem.stringValue = text ?? "" }

    func show(cursor: (line: Int, column: Int)?) {
        place.stringValue = cursor.map { String(localized: "Line \($0.line), Column \($0.column)") } ?? ""
    }
}

extension EditorStatusBar {
    /// The menu of editor options: wrapping, auto-save, format on save, and a link to Editor Settings.
    static func menu(_ app: AppModel, language: String?) -> NSMenu {
        let menu = NSMenu()
        menu.add(String(localized: "Wrap Long Lines")) { app.extensions.run("editor.toggleWordWrap") }.state =
            app.settings[SettingKeys.wordWrap, language: language] ? .on : .off
        menu.addToggle(SettingKeys.autoSave, app, title: String(localized: "Save Automatically"))
        menu.addToggle(SettingKeys.formatOnSave, app, title: String(localized: "Format on Save"))
        menu.addItem(.separator())
        menu.addSettingsLink(String(localized: "Editor Settings…"), section: "editor", app)
        return menu
    }
}
