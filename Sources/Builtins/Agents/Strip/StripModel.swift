// The agent strip's values and the pure logic behind them: its items, corners and place, what it shows.
import AppKit
import Core
import DesignKit
import KelpKit

/// One workspace on the strip: the state that wants you most among its agents, and the agent that is about.
struct StripItem: Equatable {
    var workspace: String, name: String
    var repo: String?
    var cell: DockFace.Cell
    var session: String
    /// Each of its agents, "state · title", the one above first with its words: what the tile's one mark leaves out. The state
    /// leads, so a long title is what gets cut.
    var agents: [String] = []
    /// What it says: what the agent asks, what failed or what it did; while they work, just that and how many (their chats'
    /// titles are in the tip), so a pill that says what to do and one that says nothing to do don't read alike.
    var words: String?
    var since: Date
}

/// Where the strip stands: a corner of a screen, or the middle of its foot or head. It snaps to the nearest after a drag, as a
/// picture-in-picture window does, and widens away from its corner when a pill opens. Kept per Mac: it's about this Mac's screens.
enum StripCorner: String, CaseIterable {
    case bottom, bottomLeft, bottomRight, top, topLeft, topRight
    var isTop: Bool { [.top, .topLeft, .topRight].contains(self) }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isRight: Bool { self == .bottomRight || self == .topRight }
}

struct StripPlace: Equatable {
    var corner: StripCorner
    var display: UInt32?
    /// Hidden behind this side, `y` up from the foot of the screen's visible part.
    var edge: StripEdge?
    var y: CGFloat = 0

    private static let key = "agents.dockStrip.place"
    static func load() -> StripPlace? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key),
            let corner = (saved["corner"] as? String).flatMap(StripCorner.init)
        else { return nil }
        return StripPlace(
            corner: corner, display: (saved["display"] as? NSNumber)?.uint32Value,
            edge: (saved["edge"] as? String).flatMap(StripEdge.init),
            y: (saved["y"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0)
    }
    static func save(_ place: StripPlace?) {
        guard let place else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        var saved: [String: Any] = ["corner": place.corner.rawValue, "y": Double(place.y)]
        saved["display"] = place.display
        saved["edge"] = place.edge?.rawValue
        UserDefaults.standard.set(saved, forKey: key)
    }
}

/// What the strip shows, without a window.
@MainActor
enum StripModel {
    /// How long finished work stays after it's been seen in Kelp: time to get to it from the strip.
    static let recent: TimeInterval = 600

    /// What an agent says on the strip: as on the Dock's icon, but finished work stays a while once read.
    static func cell(_ s: Session, now: Date) -> DockFace.Cell? {
        if let dockCell = DockIcon.cell(s) { return dockCell }
        let finished = s.isChat && s.parent == nil && s.shownStatus == .done
        return finished && now.timeIntervalSince(s.statusAt ?? .distantPast) < recent ? .done : nil
    }

    /// In a workspace, work going on comes before work finished: a project is done once nothing in it works, as an agent waits
    /// for the ones it started. Across workspaces finished work opens first (`opened`): it's news, work isn't.
    private nonisolated static let inWorkspace: [DockFace.Cell] = [.asks, .failed, .working, .done]

    static func status(_ c: DockFace.Cell) -> AgentStatus {
        switch c {
        case .asks: .waiting
        case .failed: .error
        case .working: .working
        case .done: .done
        }
    }

    static func items(
        _ sessions: [Session], workspaces: [(id: String, name: String, repo: String?)], now: Date = Date()
    ) -> [StripItem] {
        let byWorkspace = Dictionary(grouping: sessions) { $0.worktreeId }   // once, not a scan per workspace
        return workspaces.compactMap { workspace in
            func rank(_ a: (Session, DockFace.Cell)) -> (Int, Date) {
                (inWorkspace.firstIndex(of: a.1) ?? 0, a.0.statusAt ?? a.0.createdAt)
            }
            let own = (byWorkspace[workspace.id] ?? []).compactMap { session in
                cell(session, now: now).map { (session, $0) }
            }
            .sorted { rank($0) < rank($1) }
            guard let (lead, worst) = own.first else { return nil }
            let says = lead.summary.isEmpty ? nil : lead.summary, busy = own.count { $0.1 == .working }
            let words =
                switch worst {
                case .asks: says ?? String(localized: "Needs your input")
                case .failed: says ?? String(localized: "Failed")
                case .done: says.map { String(localized: "Done: \($0)") } ?? String(localized: "Done")
                case .working where busy > 1: String(localized: "Working: \(busy)")
                case .working: String(localized: "Working")
                }
            let said = worst == .working ? status(worst).words : brief(words)
            let agents =
                ["\(said) · \(lead.displayTitle)"]
                + own.dropFirst().map { "\(status($0.1).words) · \($0.0.displayTitle)" }
            return StripItem(
                workspace: workspace.id, name: workspace.name, repo: workspace.repo, cell: worst, session: lead.id,
                agents: agents,
                words: words,
                since: lead.statusAt ?? lead.createdAt)
        }
    }

    /// The one that opens into a pill, so the strip always says something in words: the oldest question, else what failed,
    /// what finished, what works. The others stay tiles where they are, and say theirs under the pointer.
    static func opened(_ items: [StripItem]) -> String? {
        items.min { ($0.cell, $0.since) < ($1.cell, $1.since) }?.workspace
    }

    /// `front`: Kelp is the active app, and its window already says all this. `comesFor`: what brings it up (When Needed):
    /// a finished agent can wait for a look, and it would otherwise keep the strip up all day in another app.
    static func shows(_ items: [StripItem], mode: String?, comesFor: String?, front: Bool) -> Bool {
        guard !front, mode != "off" else { return false }
        guard mode == "needed" else { return !items.isEmpty }   // Always, the default: it's where you see them working
        let loudest: DockFace.Cell =
            switch comesFor {
            case "questions": .asks
            case "all": .done
            default: .failed
            }
        return items.contains { $0.cell != .working && $0.cell <= loudest }
    }

    /// The pill's words: what a command is, without the variables set before it. Only here, for a glance: the card beside Allow
    /// says the whole command, as `LD_PRELOAD=… npm test` isn't `npm test`.
    static func brief(_ words: String) -> String {
        guard words.hasPrefix("Allow ") else { return words }
        let parts = words.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true)
        let rest = parts.drop { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*$"#, options: .regularExpression) != nil }
        return rest.isEmpty ? words : "Allow " + rest.joined(separator: " ")
    }

    /// From the screen's edges.
    static let margin: CGFloat = 8

    /// At its corner, whole on the screen.
    static func frame(_ size: NSSize, in area: NSRect, at corner: StripCorner) -> NSRect {
        let left =
            corner.isLeft
            ? area.minX + margin : corner.isRight ? area.maxX - size.width - margin : area.midX - size.width / 2
        let bottom = corner.isTop ? area.maxY - size.height - margin : area.minY + margin
        return NSRect(x: left, y: bottom, width: size.width, height: size.height)
    }

    /// The corner a strip let go here goes to.
    static func corner(nearest frame: NSRect, in area: NSRect) -> StripCorner {
        func gap(_ c: StripCorner) -> CGFloat {
            let at = Self.frame(frame.size, in: area, at: c)
            return hypot(at.midX - frame.midX, at.midY - frame.midY)
        }
        return StripCorner.allCases.min { gap($0) < gap($1) } ?? .bottom
    }

    /// A question put off: it comes back as a new one when the agent's state changes.
    static func key(_ s: Session) -> String { "\(s.id)|\(s.statusAt?.timeIntervalSince1970 ?? 0)" }
}
