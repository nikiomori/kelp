import AppKit
import Core
import DesignKit
import Foundation
import Testing

@testable import KelpApp
@testable import KelpKit

@MainActor private func texts(_ view: NSView?) -> [String] {
    guard let view else { return [] }
    return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
}

// The sidebar keeps its state in UserDefaults, the process's: one at a time.
extension OneAtATime {
    /// A project's name stands in the middle of its pill whatever happens to the rows above it. A folded project's row
    /// has its card's room over and under its name, and the name's place is asked of the row itself: taken from a
    /// list of heights by row number, which names another row once rows trade places, it stood 6 pt above its pill.
    @Test func aProjectsNameStaysInItsPillWhenAProjectAboveFolds() throws {
        let first = Repo(id: "r1", name: "Atlas", path: "/tmp/kelp-screen-atlas")
        let second = Repo(id: "r2", name: "Beta", path: "/tmp/kelp-screen-beta")
        let chats = [
            Session(worktreeId: "a", cwd: "/", command: "claude", agent: "claude", status: .working, title: "One"),
            Session(worktreeId: "a", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Two"),
            Session(worktreeId: "b", cwd: "/", command: "claude", agent: "claude", status: .working, title: "Three")
        ]
        try withSidebar(
            repos: [first, second],
            worktrees: [
                Worktree(id: "a", repoId: "r1", branch: "main", path: first.path),
                Worktree(id: "b", repoId: "r2", branch: "main", path: second.path)
            ],
            sessions: chats
        ) { vc, o in
            @MainActor func projectRow(_ name: String) throws -> Int {
                let found = (0..<o.numberOfRows).first {
                    o.level(forRow: $0) == 0
                        && texts(o.view(atColumn: 0, row: $0, makeIfNecessary: true)).contains(name)
                }
                return try #require(found)
            }
            /// Where the outline puts the row's content, measured from the row's top.
            @MainActor func name(_ title: String) throws -> NSRect {
                let row = try projectRow(title)
                return o.frameOfCell(atColumn: 0, row: row).offsetBy(dx: 0, dy: -o.rect(ofRow: row).minY)
            }
            let own = TextSize.of(vc.rowBase), ends = (top: SidebarRowView.pad, bottom: SidebarRowView.pad)
            for title in ["Beta", "Atlas"] {   // the lower one folds first, then the one above it
                vc.toggle(try #require(o.item(atRow: try projectRow(title)) as? SidebarController.Node))
                let beta = try name("Beta")
                #expect(beta.minY == ends.top && beta.height == own, "after \(title) folded: \(beta)")
            }
            // The list of heights by row number goes stale when rows trade places and their count stays (only the
            // rows with news are asked again): another row's height at this number must not move the name.
            vc.rowHeights = vc.rowHeights.map { _ in own }
            let beta = try name("Beta")
            #expect(beta.minY == ends.top && beta.height == own, "with a stale list of heights: \(beta)")
        }
    }
}
