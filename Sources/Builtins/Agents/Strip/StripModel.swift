// The agent strip's values and the pure logic behind them: its items, corners and place, what it shows.
import AppKit
import Core
import DesignKit
import KelpKit

extension DockFace.Cell {
    /// The colour of what the agent says on the strip: orange when it asks, red when it failed, quiet otherwise.
    var wordsColor: NSColor { self == .asks ? .textOrange : self == .failed ? .textRed : .secondaryLabelColor }
}

/// One workspace on the strip. It carries the most urgent state among its agents, and the agent in that state.
struct StripItem: Equatable {
    var workspace: String, name: String
    var repo: String?
    var cell: DockFace.Cell
    var session: String
    /// Each of the workspace's agents as "state · title", with the lead agent first and its words. This is what the
    /// tile's single mark leaves out. The state comes first, so a long title is what gets cut.
    var agents: [String] = []
    /// What the tile says: what the agent asks, what failed or what it did. While the agents work, it says only that
    /// and how many are working (their chats' titles are in the tip), so a pill that says what to do doesn't read like
    /// one with nothing to do.
    var words: String?
    var since: Date
    /// What the lead agent's mark draws beyond its state (`StatusMark.follow`: dots, dashes, pulse, pie, clock), so the
    /// tile changes when it does.
    var form = ""
    /// The branch's CI as the sidebar row shows it, with the mark, what it says ("CI: Failed · Tests") and where a
    /// click goes.
    var ci: RowMark?
}

/// Where the strip stands: a corner of a screen, or the middle of its bottom or top edge. After a drag it snaps to the
/// nearest place, as a picture-in-picture window does, and it widens away from its corner when a pill opens. It is
/// saved per Mac, because it depends on this Mac's screens.
enum StripCorner: String, CaseIterable, Codable {
    case bottom, bottomLeft, bottomRight, top, topLeft, topRight
    var isTop: Bool { [.top, .topLeft, .topRight].contains(self) }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isRight: Bool { self == .bottomRight || self == .topRight }
}

struct StripPlace: Equatable, Codable {
    var corner: StripCorner
    var display: UInt32?
    /// The side the strip hides behind, if any. `y` is its height above the bottom of the screen's visible part.
    var edge: StripEdge?
    var y: CGFloat = 0

    private static let key = "agents.dockStrip.place"
    static func load() -> StripPlace? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do { return try JSONDecoder().decode(StripPlace.self, from: data) } catch { return nil }
    }
    static func save(_ place: StripPlace?) {
        do { UserDefaults.standard.set(try place.map { try JSONEncoder().encode($0) }, forKey: key) } catch {}
    }
}

/// Works out what the strip shows, without a window.
@MainActor
enum StripModel {
    /// How long finished work stays on the strip after the user saw it in Kelp, so there is time to get to it from the
    /// strip.
    static let recent: TimeInterval = 600

    /// Returns the agent's state on the strip. It matches the Dock icon, except that finished work stays a while after
    /// it was read.
    static func cell(_ session: Session, now: Date) -> DockFace.Cell? {
        if let dockCell = DockIcon.cell(session) { return dockCell }
        let finished = session.isChat && session.parent == nil && session.shownStatus == .done
        return finished && now.timeIntervalSince(session.statusAt ?? .distantPast) < recent ? .done : nil
    }

    /// Within a workspace, work going on ranks before finished work, because a project is done only once nothing in it
    /// works, just as an agent waits for the agents it started. Across workspaces, finished work opens first
    /// (`opened`), because it is news and work going on isn't.
    private nonisolated static let inWorkspace: [DockFace.Cell] = [.asks, .failed, .working, .done]

    static func status(_ cell: DockFace.Cell) -> AgentStatus {
        switch cell {
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
            func rank(_ entry: (Session, DockFace.Cell)) -> (Int, Date) {
                (inWorkspace.firstIndex(of: entry.1) ?? 0, entry.0.statusAt ?? entry.0.createdAt)
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
                since: lead.statusAt ?? lead.createdAt,
                form: "\(lead.limitHit != nil) \(lead.compacting) \(lead.waitsForCommand) \(lead.guessed == true) "
                    + "\(lead.progress ?? -1)")
        }
    }

    /// Returns the workspace that opens into a pill, so the strip always says something in words. It is the oldest
    /// question, or else what failed, what finished, or what works. The other workspaces stay tiles where they are,
    /// and say what they have to say under the pointer.
    static func opened(_ items: [StripItem]) -> String? {
        items.min { ($0.cell, $0.since) < ($1.cell, $1.since) }?.workspace
    }

    /// Whether the strip shows. `front` means Kelp is the active app, whose window already says all this. `comesFor` is
    /// what brings the strip up in When Needed mode, because a finished agent can wait for a look and would otherwise
    /// keep the strip up all day over another app.
    static func shows(_ items: [StripItem], mode: String?, comesFor: String?, front: Bool) -> Bool {
        guard !front, mode != "off" else { return false }
        guard mode == "needed" else { return !items.isEmpty }   // Always, the default, also shows agents at work
        let loudest = loudest(comesFor)
        return items.contains { $0.cell != .working && $0.cell <= loudest }
    }

    /// Returns the quietest news that brings the strip up (the Comes Up For setting). That is questions only, failures
    /// too (the default), or finished work as well.
    static func loudest(_ comesFor: String?) -> DockFace.Cell {
        switch comesFor {
        case "questions": .asks
        case "all": .done
        default: .failed
        }
    }

    /// Returns the pill's words, with a command shown without the variables set before it. This short form is only for
    /// a glance at the pill. The card beside Allow shows the whole command, because `LD_PRELOAD=… npm test` isn't
    /// `npm test`.
    static func brief(_ words: String) -> String {
        guard words.hasPrefix("Allow ") else { return words }
        let parts = words.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true)
        let rest = parts.drop { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*$"#, options: .regularExpression) != nil }
        return rest.isEmpty ? words : "Allow " + rest.joined(separator: " ")
    }

    /// The strip's distance from the screen's edges.
    static let margin: CGFloat = 8

    /// Returns the strip's frame at its corner, wholly on the screen.
    static func frame(_ size: NSSize, in area: NSRect, at corner: StripCorner) -> NSRect {
        let left =
            corner.isLeft
            ? area.minX + margin : corner.isRight ? area.maxX - size.width - margin : area.midX - size.width / 2
        let bottom = corner.isTop ? area.maxY - size.height - margin : area.minY + margin
        return NSRect(x: left, y: bottom, width: size.width, height: size.height)
    }

    /// Returns the corner that a strip let go at `frame` goes to.
    static func corner(nearest frame: NSRect, in area: NSRect) -> StripCorner {
        func gap(_ stripCorner: StripCorner) -> CGFloat {
            let at = Self.frame(frame.size, in: area, at: stripCorner)
            return hypot(at.midX - frame.midX, at.midY - frame.midY)
        }
        return StripCorner.allCases.min { gap($0) < gap($1) } ?? .bottom
    }

    /// The key a put-off question is kept by. It includes the time of the agent's state, so the question comes back as
    /// a new one when that state changes.
    static func key(_ session: Session) -> String { "\(session.id)|\(session.statusAt?.timeIntervalSince1970 ?? 0)" }
}

/// What a card over the strip answers, by what the agent waits on.
enum StripCardKind: Equatable {
    /// Allow or Deny, with the whole of what the agent would do shown above them.
    case permission
    /// The answers to the agent's question, one click each.
    case choices([String])
    /// The agent is back at its prompt (done or failed), so the card takes a typed line or the quick reply.
    case reply
    /// Nothing can be answered from the card (a question in words, or a menu of several questions), so it opens in
    /// Kelp.
    case look

    @MainActor static func of(_ session: Session) -> StripCardKind {
        if session.asksPermission { return .permission }
        if session.status == .waiting, let choices = session.choices, !choices.isEmpty { return .choices(choices) }
        return QuickReply.fits(session) ? .reply : .look
    }
}

extension StripModel {
    /// Splits a permission's question the way the card shows it: the kind of thing it allows, above the thing itself in
    /// full. "Allow npm test?" becomes "Allow this command?" above `npm test`, and "Allow editing App.swift?" becomes
    /// "Allow editing?" above the path. A bare tool ("Allow github: create_issue?") stays as it is. For a routine an
    /// agent asks for, the detail is all of it, as the daemon wrote it.
    static func permission(_ summary: String) -> (title: String, detail: String?) {
        guard summary.hasPrefix("Allow "), summary.hasSuffix("?") else { return (summary, nil) }
        let what = String(summary.dropFirst(6).dropLast())
        let kinds = [
            ("editing", String(localized: "Allow editing?")), ("writing", String(localized: "Allow writing?")),
            ("reading", String(localized: "Allow reading?")), ("fetching", String(localized: "Allow fetching?")),
            ("searching the web for", String(localized: "Allow a web search?")),
            ("a routine,", String(localized: "Allow this routine?"))
        ]
        for (verb, title) in kinds where what.hasPrefix(verb + " ") {
            return (title, what.dropFirst(verb.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "“”")))
        }
        guard what.contains(" "), !what.contains(": ") else { return (summary, nil) }
        return (String(localized: "Allow this command?"), what)
    }
}
