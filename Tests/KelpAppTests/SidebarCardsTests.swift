import AppKit
import Core
import Foundation
import Testing

@testable import KelpApp
@testable import KelpKit

/// A project with a chat (Atlas), one with nothing under it (Beta), a folded server (beet) whose project doesn't show, a
/// server (kale) with its project showing, and Chats at the end. `coloured` gives the projects with nothing under them a
/// colour.
@MainActor private func withCards(
    _ look: String, coloured: Bool, _ check: @MainActor (SidebarController, [String: NSRect]) throws -> Void
) throws {
    func remote(_ host: String, _ name: String) throws -> String {
        let folder = Paths.root.appendingPathComponent("remote/\(host)/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(RemoteHost(host: host, path: "/srv/\(name)")).write(
            to: folder.appendingPathComponent(RemoteHost.marker))
        return folder.path
    }
    let atlas = Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-cards-atlas")
    let repos = [
        atlas, Repo(id: "r2", name: "Beta", path: "/tmp/kelp-cards-beta"),
        Repo(id: "r3", name: "infra", path: try remote("beet", "infra")),
        Repo(id: "r4", name: "web", path: try remote("kale", "web")),
        Repo(id: "np", name: "Chats", path: NoProject.path)
    ]
    let chat = Session(worktreeId: "a", cwd: "/", command: "claude", agent: "claude", status: .working, title: "One")
    try withSidebar(
        repos: repos, worktrees: [Worktree(id: "a", repoId: "r1", branch: "main", path: atlas.path)],
        sessions: [chat],
        settings: ["workbench.sidebar.rowHeight": "large", "workbench.sidebar.projectColor": .string(look)]
    ) { vc, _ in
        if coloured { for id in ["r2", "r4", "np"] { vc.app.arrangement.projectColors[id] = .blue } }
        vc.collapsed.insert("h:beet")
        vc.app.extensions.reload()   // the server headers are the Servers built-in's
        vc.refresh()
        vc.placeCards()
        try check(vc, vc.cards.mapValues(\.frame))
    }
}

/// The cards that aren't inside another, top to bottom.
private func outer(_ cards: [String: NSRect]) -> [(key: String, frame: NSRect)] {
    cards.filter { card in !cards.contains { $0.key != card.key && $0.value.contains(card.value) } }
        .map { (key: $0.key, frame: $0.value) }.sorted { $0.frame.minY < $1.frame.minY }
}

// The sidebar keeps its state in UserDefaults, the process's: one at a time.
extension OneAtATime {
    /// Every card starts 8 pt from the sidebar's edge and ends where the others end. A server's card round its
    /// projects reaches 2 pt past their cards.
    @Test func everyCardStartsAndEndsAtTheSameEdges() throws {
        try withCards("card", coloured: true) { _, cards in
            let atlas = try #require(cards["p:r1"])
            for (key, frame) in cards where key != "s:kale" {
                #expect(frame.minX == 8 && frame.maxX == atlas.maxX, "\(key): \(frame)")
            }
            let kale = try #require(cards["s:kale"]), web = try #require(cards["p:r4"])
            #expect(kale.minX == web.minX - 2 && kale.maxX == web.maxX + 2 && kale.maxY == web.maxY + 2)
        }
    }

    /// A one-line card is 36 pt tall at Large rows: a project's, a folded server's, Chats'.
    @Test func everyOneLineCardIsAsTallAsTheNext() throws {
        try withCards("card", coloured: true) { _, cards in
            for key in ["p:r2", "s:beet", "p:r4", "p:np"] {
                #expect(cards[key]?.height == 36, "\(key): \(String(describing: cards[key]))")
            }
        }
    }

    /// There is one step of 8 pt between any two cards: projects, servers and Chats.
    @Test func cardsStandOneStepApart() throws {
        try withCards("card", coloured: true) { _, cards in
            let order = outer(cards)
            #expect(order.map(\.key) == ["p:r1", "p:r2", "s:beet", "s:kale", "p:np"])
            for (above, below) in zip(order, order.dropFirst()) {
                #expect(below.frame.minY - above.frame.maxY == 8, "\(above.key) → \(below.key)")
            }
        }
    }

    /// In the Filled Card look every project is a card, one with nothing under it and no colour too.
    @Test func inTheFilledCardLookEveryProjectIsACard() throws {
        try withCards("card", coloured: false) { _, cards in
            #expect(Set(cards.keys) == ["p:r1", "p:r2", "s:beet", "s:kale", "p:r4", "p:np"])
        }
    }

    /// On the Icon, a project with nothing under it has no card, and keeps the room one would take: the cards round it
    /// stay on the same step.
    @Test func aPlainRowKeepsTheRoomOfACard() throws {
        try withCards("icon", coloured: false) { _, cards in
            #expect(cards["p:r2"] == nil && cards["p:np"] == nil)
            let atlas = try #require(cards["p:r1"]), beet = try #require(cards["s:beet"])
            let plain: CGFloat = 8 + 36 + 8   // a step, the card Beta would have, a step
            #expect(beet.minY - atlas.maxY == plain)
        }
    }
}
