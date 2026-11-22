import AppKit
import Core
import DesignKit
import SwiftUI

/// An extension list's rows: its icon when that names a field, the title with the subtitle under it, the status mark at
/// the end (a spinner there while its action takes over a second); the actions on a double-click, Return and a
/// right-click; and the file a row drags.
extension ExtListView {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { tableView.listRowView() }
    /// Rows as tall as the inspector's (24, or 40 with a line under the name), growing with Text size.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        TextSize.of(def.subtitle == nil ? Metrics.row : Metrics.rowTwoLine)
    }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        items.indices.contains(row) ? cell(items[row], key: rowKeys[row]) : nil
    }

    private func cell(_ item: JSONValue, key: String) -> NSView {
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
        if slow.keys.contains(where: { $0.first == key }) {
            cell.setViews([Self.spinner()], in: .trailing)
        } else if let status = status(item) {
            cell.setViews([mark(status)], in: .trailing)
        }
        return cell
    }

    /// `working` is the grey filled dot Settings shows for "on" (`StateDot`): the turning ring is an agent's, and only
    /// an agent's state moves by itself. The others keep their still shapes.
    private func mark(_ status: AgentStatus) -> NSView {
        if status == .working { return NSHostingView(rootView: StateDot(on: true)) }
        let mark = StatusMark(size: 12)
        mark.status = status
        return mark
    }

    /// The system's small spinner, as the interface waits (the turning ring is an agent's mark for working).
    private static func spinner() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        return spinner
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

    /// A double-click, or Return on the selected row, runs the first action the row offers (`ExtActions.offered`).
    @objc func doubleClicked() { runFirst(on: table.clickedRow) }
    func runFirst(on row: Int) {
        guard items.indices.contains(row),
            let action = def.actions?.first(where: { ExtActions.offered($0, on: items[row]) })
        else { return }
        perform(action, items[row], key: rowKeys[row])
    }
    /// Runs a row's action unless that one is still under way there. A `run` that takes over a second puts the
    /// spinner at the row's end until it ends.
    private func perform(_ action: ExtManifest.ActionDef, _ item: JSONValue, key: String) {
        let job = [key, action.title]
        guard running.insert(job).inserted else { return }
        ExtActions(app).perform(
            action, item: item, folder: folder, busy: { [weak self] on in self?.busy(job, on) }
        ) { [weak self] in
            self?.running.remove(job)
            self?.reload()
        }
    }

    private func busy(_ job: [String], _ on: Bool) {
        if on {
            slow[job] = .now
            return redraw(job[0])
        }
        running.remove(job)   // also a question answered "Cancel"
        guard let shown = slow[job] else { return }
        Task { [weak self] in
            let left = max(0, LoadingView.held - Date.now.timeIntervalSince(shown))
            do { try await Task.sleep(for: .seconds(left)) } catch { return }
            self?.slow[job] = nil
            self?.redraw(job[0])
        }
    }

    private func redraw(_ key: String) {
        guard let row = rowKeys.firstIndex(of: key) else { return }
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    /// A row's right-click menu: every action the row offers, with its symbol when it names one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard items.indices.contains(table.clickedRow) else { return }
        let item = items[table.clickedRow], key = rowKeys[table.clickedRow]
        for action in def.actions ?? [] where ExtActions.offered(action, on: item) {
            menu.add(action.shownTitle, symbol: action.icon) { [weak self] in self?.perform(action, item, key: key) }
        }
    }

    /// `drag`: the row drags that file (into Finder, a terminal, an agent's prompt).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let drag = def.drag, items.indices.contains(row) else { return nil }
        let path = ExtActions(app).expand(drag, item: items[row], quote: false)
        return path.isEmpty ? nil : URL(fileURLWithPath: path) as NSURL
    }
}
