import AppKit
import Core
import DesignKit
import KelpKit
import WorkbenchKit

/// The Map tab: one agent's work as a tree of nodes (`work:<session>`).
@MainActor
final class WorkTab: KelpKit.TabContent {
    static let scheme = "work"
    static func uri(_ session: String) -> String { "\(scheme):\(session)" }
    static func title(_ session: Session?, app: AppModel) -> String {
        session.map { String(localized: "Map · \(app.catalog.displayName($0))") } ?? String(localized: "Map")
    }

    let uri: String
    let view: NSView
    private let app: AppModel
    private let controller: WorkMapController
    var title: String { Self.title(app.session(TabURI.body(uri)), app: app) }
    var icon: NSImage? { .symbol("map") }

    init(uri: String, app: AppModel) {
        self.uri = uri
        self.app = app
        controller = WorkMapController(app: app, session: TabURI.body(uri))
        view = controller.view
    }
    func focus() { view.window?.makeFirstResponder(controller.tree) }
}
