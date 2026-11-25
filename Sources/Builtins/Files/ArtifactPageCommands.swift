import AppKit
import KelpKit

extension Builtins {
    /// The page in the focused tab when it is a canvas or a motion page, else nil (with no beep: menus ask it).
    static func boardsPage(_ app: AppModel) -> MarkdownTab? {
        guard let tab = (app.workbench.focusedContent as? FileTab)?.markdown, tab.page == .canvas || tab.page == .motion
        else { return nil }
        return tab
    }

    /// What a canvas's or a motion page's own controls and right-click menu do, as commands too: in the menu bar and
    /// ⇧⌘P, each able only where it applies (a motion page; an element chosen in Edit).
    static func artifactPageCommands(_ app: AppModel) -> [CommandSpec] {
        let motion = { boardsPage(app).flatMap { $0.page == .motion ? $0 : nil } }
        let chosen = { boardsPage(app).flatMap { tab in tab.chosen.map { (tab, $0.board, $0.id) } } }
        func element(
            _ id: String, _ title: String, _ menu: String, _ run: @escaping (MarkdownTab, String, String) -> Void
        )
            -> CommandSpec
        {
            CommandSpec(id: id, title: title, menu: menu, enabled: { chosen() != nil }) { _ in
                guard let (tab, board, element) = chosen() else { return NSSound.beep() }
                run(tab, board, element)
            }
        }
        return [
            CommandSpec(id: "artifacts.playPause", title: "Play or Pause", menu: "View", enabled: { motion() != nil }) {
                _ in motion()?.runJS("window.kelpMotion?.toggle()")
            },
            CommandSpec(
                id: "artifacts.exportVideo", title: "Export Video…", menu: "File", enabled: { motion() != nil }
            ) { _ in motion()?.motionStudio.openExport() },
            CommandSpec(
                id: "artifacts.export", title: "Export Page…", menu: "File", enabled: { artifactPage(app) != nil }
            ) {
                args in exportPage(app, args)
            },
            element("artifacts.duplicateElement", "Duplicate Element", "Edit") { tab, board, id in
                tab.duplicateElement(board, id)
            },
            element("artifacts.bringToFront", "Bring to Front", "Edit") { tab, _, _ in
                tab.runJS("window.kelpArrange?.(true)")
            },
            element("artifacts.sendToBack", "Send to Back", "Edit") { tab, _, _ in
                tab.runJS("window.kelpArrange?.(false)")
            },
            element("artifacts.replaceImage", "Replace Picture…", "Edit") { tab, board, id in
                tab.replaceImage(board, id)
            },
            element("artifacts.deleteElement", "Delete Element", "Edit") { tab, board, id in
                tab.removeElement(board, id)
            }
        ]
    }
}
