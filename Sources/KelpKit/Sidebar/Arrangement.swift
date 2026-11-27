import Core
import Foundation

/// How the user arranged the sidebar, kept in the daemon's UI state (`state.set`): the order rows were dragged into,
/// the rows muted or parked, and the projects' colours. It belongs to the sidebar, and sits next to AppModel's mirror
/// of the daemon.
@MainActor
@Observable
final class Arrangement {
    @ObservationIgnored unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    /// Project and workspace ids in the order they were dragged into in the sidebar. Ids never moved come after them.
    var order: [String] = [] {
        didSet {
            rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            app.uiState[StateKeys.sidebarOrder] = try? .from(order)
        }
    }
    /// Each id's place in `order`. It is made once each time `order` changes, not each time a list is sorted.
    private(set) var rank: [String: Int] = [:]
    /// Removes projects and workspaces that were removed from the order, which otherwise kept every id ever dragged.
    /// It runs only on a removal the daemon reported, never from a list (a list not read yet would say everything is
    /// gone).
    func forget(_ ids: [String]) {
        let gone = Set(ids)
        if order.contains(where: gone.contains) { order.removeAll(where: gone.contains) }
    }
    /// Muted rows: id → until when (`Mutes`).
    var mutes: [String: Date] = [:] { didSet { app.uiState[StateKeys.muted] = Mutes.value(mutes) } }
    /// Agents parked: id → until when (`Parking`).
    var parked: [String: Date] = [:] {
        didSet {
            app.uiState[Parking.key] = Mutes.value(parked)
            endParksOnTime()
        }
    }
    /// Why a parked agent came back. It shows on the agent's row until the agent is opened.
    var parkedBack: [String: String] = [:]
    /// The runs failed at each folder's last CI reading (`followParked`), so only a run that newly failed brings an
    /// agent back. Kept past the reading being forgotten: the same old failure read again is no news.
    @ObservationIgnored var ciFailed: [String: Set<Int>] = [:]
    /// Each project's colour, by id.
    var projectColors: [String: ProjectColor] = [:] {
        didSet { app.uiState[ProjectColor.key] = ProjectColor.value(projectColors) }
    }
    /// The colour a project would get from the dot under the pointer in its menu. It is shown but not kept.
    var colorPreview: (project: String, color: ProjectColor?)?
}
