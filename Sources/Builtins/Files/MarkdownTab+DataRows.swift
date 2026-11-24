import AppKit
import Core
import DesignKit
import KelpKit
import UniformTypeIdentifiers

/// A page shown and exported a copy a row of a table (`DataRows`, `CanvasData`): the tab reads the CSV files beside
/// the page for it, writes which column an element takes, and makes a video or the boards' pictures for each row.
extension MarkdownTab {
    func rowsMessage(_ kind: String, _ body: [String: Any]) -> Bool {
        let board = body["board"] as? String ?? "", id = body["id"] as? String ?? ""
        switch kind {
        case "rowsNeed": loadRows(body["files"] as? [String] ?? [])
        case "rowsTable": chooseTable(board, id)
        case "rowsField":
            let file = body["file"] as? String ?? "", menu = NSMenu()
            for column in body["columns"] as? [String] ?? [] {
                menu.add(column) { [weak self] in self?.setField(board, id, file + ":" + column) }
            }
            menu.addItem(.separator())
            menu.add(String(localized: "Not from Data")) { [weak self] in self?.setField(board, id, nil) }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        default: return false
        }
        return true
    }

    private var pageFolder: URL { url.deletingLastPathComponent() }

    /// The rows of each of `files` (beside the page), given to the page.
    private func loadRows(_ files: [String]) {
        Task {
            var tables: [String: [[String]]] = [:]
            for file in files where !file.contains("/") && !file.contains("..") {
                let path = pageFolder.appendingPathComponent(file).path
                if let read = await app.quiet(FilesRead(path: path)) { tables[file] = DataRows.parse(read.text) }
            }
            runJS("window.kelpSetRows?.(\(Self.js(tables)))")
        }
    }

    /// Table: a CSV file, copied beside the page when it is elsewhere; the element takes its first column.
    private func chooseTable(_ board: String, _ id: String) {
        Task {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.directoryURL = pageFolder
            guard await runSheet(panel) == .OK, let file = panel.url else { return }
            var name = file.lastPathComponent
            if file.deletingLastPathComponent().standardizedFileURL.path != pageFolder.standardizedFileURL.path {
                guard let made = await app.call(FilesCopy(paths: [file.path], into: pageFolder.path))?.made.first
                else { return }
                name = (made as NSString).lastPathComponent
            }
            let read = await app.quiet(FilesRead(path: pageFolder.appendingPathComponent(name).path))
            guard let first = read.flatMap({ DataRows.parse($0.text).first?.first }) else {
                return Banner.show(String(localized: "“\(name)” has no columns."), style: .error)
            }
            setField(board, id, name + ":" + first)
        }
    }

    private func setField(_ board: String, _ id: String, _ value: String?) {
        let edit = { (source: String) in
            HandEdit(
                board: board, id: id, what: "data-field",
                from: BoardEdit.attribute(source, id: id, name: "data-field"), to: value)
        }
        rewrite(board, edit: edit) { BoardEdit.setAttribute($0, id: id, name: "data-field", value: value) }
    }

    /// For Each Row…: into a folder, a video (a motion page) or the boards' pictures (a design) for each row, named by
    /// its first cell.
    func exportEachRow() {
        Task {
            var names: [String] = []
            do {
                names =
                    try await web.evaluateJavaScript("window.kelpRowNames?.() ?? []", contentWorld: Self.world)
                    as? [String] ?? []
            } catch { names = [] }   // a page that can't answer has no rows
            guard !names.isEmpty else {
                return Banner.show(String(localized: "Nothing on this page takes a column of a table yet."))
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Export Here")
            guard await runSheet(panel) == .OK, let folder = panel.url else { return }
            for (i, row) in names.enumerated() {
                runJS("window.kelpRow?.(\(i + 1))")
                let name = DataRows.name([row], index: i + 1)
                if page == .motion {
                    let to = folder.appendingPathComponent(name + ".mp4"), item = MotionExports.Item(to)
                    motionStudio.exports.insert(item, at: 0)
                    await record(to: to, MotionExport(), item)
                } else {
                    do { try await exportBoards(into: folder.appendingPathComponent(name), row: i + 1) } catch {
                        Banner.show(String(localized: "Couldn’t export: \(error.localizedDescription)"), style: .error)
                        break
                    }
                }
            }
            runJS("window.kelpRow?.(1)")
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
