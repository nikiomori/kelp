import AppKit
import Core
import DesignKit
import KelpKit

/// Copy or Export Rows: the rows picked (or the page) in each format, to the clipboard or a file of the user's own.
extension DatabaseTab {
    func copyMenu() {
        let menu = NSMenu()
        let picked = grid.selectedRows.isEmpty ? Array(grid.rows.indices) : grid.selectedRows
        let what = grid.selectedRows.isEmpty ? String(localized: "the Page") : Self.rows(picked.count).capitalizedFirst
        if let cut = grid.cut {   // what a statement gave past the rows shown isn't here to copy
            menu.addItem(withTitle: Self.shown(grid.rows.count, of: cut), action: nil, keyEquivalent: "").isEnabled =
                false
            menu.addItem(.separator())
        }
        for format in ResultText.Format.allCases {
            menu.add(String(localized: "Copy \(what) as \(format.rawValue)")) { [weak self] in
                guard let self else { return }
                copyText(text(format, picked))
            }
        }
        menu.addItem(.separator())
        for format in [ResultText.Format.csv, .json] {
            menu.add(String(localized: "Export \(what) as \(format.rawValue)…")) { [weak self] in
                self?.export(format, picked)
            }
        }
        if let table = current {
            menu.addItem(.separator())
            menu.add(String(localized: "Copy CREATE TABLE")) { [weak self] in
                if let self { copyText(definition(table)) }
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func text(_ format: ResultText.Format, _ picked: [Int]) -> String {
        ResultText.text(
            format, grid.columns, picked.map { grid.rows[$0] }, types: grid.types, from: (mode.table, engine))
    }

    /// Saves the rows where the user says: a file of their own choosing, not one in the project.
    private func export(_ format: ResultText.Format, _ picked: [Int]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (mode.table ?? address.name) + "." + format.fileExtension
        let body = text(format, picked)
        Task {
            guard await runSheet(panel) == .OK, let url = panel.url else { return }
            // Written off the main thread, because a big table's text may go to a slow disk.
            let written = await Task.detached { Result { try body.write(to: url, atomically: true, encoding: .utf8) } }
                .value
            if case .failure(let error) = written {
                Banner.show(
                    String(localized: "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"),
                    style: .error)
            }
        }
    }
}
