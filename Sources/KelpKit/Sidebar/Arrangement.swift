import Core
import Foundation

/// How the user arranged the sidebar, kept in the daemon's UI state (`state.set`): the order rows were dragged into,
/// rows told to keep quiet or parked, projects' colours. The sidebar's, beside AppModel's mirror of the daemon.
@MainActor
@Observable
final class Arrangement {
    @ObservationIgnored unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    /// Project and workspace ids in the order they were dragged into in the sidebar; ones never moved follow them.
    var order: [String] = [] { didSet { app.uiState["sidebar.order"] = try? .from(order) } }
    /// Rows told to keep quiet: id → until when (`Mutes`).
    var mutes: [String: Date] = [:] { didSet { app.uiState[Mutes.key] = Mutes.value(mutes) } }
    /// Agents parked: id → until when (`Parking`).
    var parked: [String: Date] = [:] {
        didSet {
            app.uiState[Parking.key] = Mutes.value(parked)
            endParksOnTime()
        }
    }
    /// Why a parked agent came back, on its row until it's opened.
    var parkedBack: [String: String] = [:]
    /// Each project's colour, by id.
    var projectColors: [String: ProjectColor] = [:] {
        didSet { app.uiState[ProjectColor.key] = ProjectColor.value(projectColors) }
    }
    /// What the dot under the pointer in a project's menu would make of it: shown, not kept.
    var colorPreview: (project: String, color: ProjectColor?)?
}
