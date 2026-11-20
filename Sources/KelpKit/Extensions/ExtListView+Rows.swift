import AppKit
import Core
import DesignKit

/// An extension list's rows: its icon when that names a field, the title with the subtitle under it, the status mark at
/// the end; the actions on a double-click, Return and a right-click; and the file a row drags.
extension ExtListView {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { tableView.listRowView() }
    /// Rows as tall as the inspector's (24, or 40 with a line under the name), growing with Text size.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        TextSize.of(def.subtitle == nil ? Metrics.row : Metrics.rowTwoLine)
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        items.indices.contains(row) ? cell(items[row]) : nil
    }

    private func cell(_ item: JSONValue) -> NSView {
        let actions = ExtActions(app)
        let title = NSTextField.label(
            actions.expand(def.title ?? "${name}", item: item, quote: false), font: .ui(TextSize.row))
        let texts = NSStackView(views: [title])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = Metrics.lineGap
        let subtitle = def.subtitle.map { actions.expand($0, item: item, quote: false) } ?? ""
        if !subtitle.trimmingCharacters(in: .whitespaces).isEmpty {
            texts.addArrangedSubview(
                NSTextField.label(subtitle, font: .ui(TextSize.caption), color: .secondaryLabelColor))
        }
        let cell = NSStackView()
        cell.spacing = Metrics.gap
        cell.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
        cell.setViews([icon(item), texts].compactMap { $0 }, in: .leading)
        if let status = status(item) {
            let mark = StatusMark(size: 12)
            mark.status = status
            cell.setViews([mark], in: .trailing)
        }
        return cell
    }

    /// An icon that's the same on every row is the panel's own icon, which its tab already shows. Only an icon that
    /// names a field tells rows apart, so only that one shows on the row.
    private func icon(_ item: JSONValue) -> NSView? {
        guard let icon = def.icon, icon.contains("${") else { return nil }
        let name = ExtActions(app).expand(icon, item: item, quote: false)
        let view: NSImageView
        if let image = Self.image(name) {
            view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.heightAnchor.constraint(equalToConstant: TextSize.of(Metrics.appIcon)).isActive = true
        } else {
            view = NSImageView(image: .symbol(name.hasPrefix("app:") ? "app.dashed" : name))
            view.symbolConfiguration = .chrome()
            view.contentTintColor = .secondaryLabelColor
        }
        view.widthAnchor.constraint(equalToConstant: TextSize.of(Metrics.appIcon)).isActive = true
        return view
    }

    @MainActor private static var images: [String: NSImage?] = [:]
    /// A row icon that isn't an SF Symbol: `app:<bundle id>` (that app's icon) or a file's path (its Finder icon).
    private static func image(_ name: String) -> NSImage? {
        guard name.hasPrefix("app:") || name.hasPrefix("/") else { return nil }
        if let cached = images[name] { return cached }
        let path =
            name.hasPrefix("/")
            ? name : NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(name.dropFirst(4)))?.path
        let image = path.map { NSWorkspace.shared.icon(forFile: $0) }
        images[name] = image
        return image
    }

    private func status(_ item: JSONValue) -> AgentStatus? {
        guard let rule = def.status, let value = item[rule.field].map(ExtActions.text),
            let mapped = rule.map[value] ?? rule.map[value.lowercased()]
        else { return nil }
        switch mapped {
        case "working": return .working
        case "waiting": return .waiting
        case "done": return .done
        case "idle": return .idle
        default: return .exited
        }
    }

    // MARK: Actions

    /// A double-click, or Return on the selected row, runs the first action.
    @objc func doubleClicked() { runFirst(on: table.clickedRow) }
    func runFirst(on row: Int) {
        guard items.indices.contains(row), let action = def.actions?.first else { return }
        perform(action, items[row])
    }
    private func perform(_ action: ExtManifest.ActionDef, _ item: JSONValue) {
        ExtActions(app).perform(action, item: item, folder: folder, after: { [weak self] in self?.reload() })
    }

    /// A row's right-click menu: every action, with its symbol when it names one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard items.indices.contains(table.clickedRow) else { return }
        let item = items[table.clickedRow]
        for action in def.actions ?? [] {
            menu.add(action.title, symbol: action.icon) { [weak self] in self?.perform(action, item) }
        }
    }

    /// `drag`: the row drags that file (into Finder, a terminal, an agent's prompt).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let drag = def.drag, items.indices.contains(row) else { return nil }
        let path = ExtActions(app).expand(drag, item: items[row], quote: false)
        return path.isEmpty ? nil : URL(fileURLWithPath: path) as NSURL
    }
}
