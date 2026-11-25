import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// What the user does to a page as a whole, from the Artifacts panel's menu and its bar's ⋯: give it a name of their
/// own, or move its folder to the Trash (from where Finder puts it back).
@MainActor
enum ArtifactActions {
    /// Asks for the page's new name; `page` is its file.
    static func rename(_ app: AppModel, page: String, title: String) {
        Task {
            let alert = NSAlert()
            alert.messageText = String(localized: "Rename Page")
            let field = NSTextField(string: title)
            field.frame.size = NSSize(width: Metrics.alertAccessory, height: field.fittingSize.height)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: String(localized: "Rename"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await runSheet(alert) == .alertFirstButtonReturn, field.stringValue != title else { return }
            await app.call(ArtifactRename(path: page, title: field.stringValue))
        }
    }

    /// Moves the page's folder to the Trash, and closes its tab.
    static func trash(_ app: AppModel, page: String) {
        let folder = (page as NSString).deletingLastPathComponent
        Task {
            guard let moved = await app.call(FilesTrash(paths: [folder])) else { return }
            if let error = moved.error { return Banner.show(error, style: .error) }
            app.workbench.closeTab(uri: TabURI.file(page))
        }
    }
}

extension ArtifactsPanel {
    /// What the filter finds a page by: its title, its kind and the agent that made it ("slides", "Codex").
    func words(_ item: ArtifactItem, _ project: String?) -> String {
        let kind = Artifacts.Kind(rawValue: item.type).map(ArtifactStart.title) ?? item.type
        let agent = item.session.flatMap(app.session)?.agent.map { app.catalog.name($0) } ?? ""
        return [title(item, project), kind, item.type, agent].joined(separator: " ")
    }
}
