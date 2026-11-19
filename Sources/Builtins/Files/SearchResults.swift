import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The Files panel's second list: the lines a search or a language server found, shown in place of the tree. A click
/// or ↩ opens the line, and the row's menu offers what the editor offers for a line.
@MainActor
final class SearchResults: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let table = KeyTable()
    let scroll = NSScrollView()
    private(set) var matches: [SearchMatch] = []
    /// For a list of problems: whether each row is an error or a warning, drawn as the status bar's signs.
    private var errors: [Bool]?
    /// The workspace folder the matches' paths are in.
    var root = "/"
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init()
        table.plainList("r", in: scroll)
        table.rowSizeStyle = .custom
        table.rowHeight = TextSize.of(Metrics.rowTwoLine)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openClicked)
        table.onReturn = { [weak self] in self?.openClicked() }
        scroll.isHidden = true
    }

    func show(_ found: [SearchMatch], errors: [Bool]? = nil) {
        matches = found
        self.errors = errors
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ListRowView() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let match = matches[row]
        let top = NSTextField.label(   // truncated at the head, so the line number at the end stays
            "\(match.path):\(match.line)", font: .uiDigits(TextSize.caption), color: .secondaryLabelColor,
            truncation: .byTruncatingHead)
        let txt = NSTextField(labelWithString: match.text)
        txt.font = .uiMono(TextSize.caption)
        txt.lineBreakMode = .byTruncatingTail
        let line: NSView
        if let errors, errors.indices.contains(row) {
            let sign = NSImageView(
                image: .symbol(
                    errors[row] ? "xmark.circle" : "exclamationmark.triangle",
                    errors[row] ? String(localized: "Error") : String(localized: "Warning")))
            sign.symbolConfiguration = .chrome(Metrics.iconTiny)
            sign.contentTintColor = errors[row] ? .textRed : .textOrange
            let pair = NSStackView(views: [sign, txt])
            pair.spacing = Metrics.gapTight
            line = pair
        } else {
            line = txt
        }
        let stack = NSStackView(views: [top, line])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.lineGap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        return stack
    }

    @objc private func openClicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if matches.indices.contains(row) { open(matches[row]) }
    }

    private func open(_ match: SearchMatch) {
        app.workbench.open(TabURI.file(root + "/" + match.path, line: match.line))
    }

    /// Builds the menu for a found line, with what the editor offers for a line.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard matches.indices.contains(table.clickedRow) else { return }
        let app = app, hit = matches[table.clickedRow], path = root + "/" + hit.path
        menu.add(String(localized: "Open")) { [weak self] in self?.open(hit) }
        menu.add(String(localized: "Open to the Side")) {
            app.workbench.open(TabURI.file(path, line: hit.line), split: .right)
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Send to Agent")) { FileActions(app).sendToAgent(path, lines: hit.line...hit.line) }
        menu.add(String(localized: "Copy Path and Line")) {
            FileActions(app).copyReference(path, lines: hit.line...hit.line)
        }
    }
}
