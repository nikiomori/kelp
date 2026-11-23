import Core
import Foundation
import Testing

@testable import BuiltinWork

private func file(_ name: String, reads: Int = 1, edits: Int = 0, agents: [Int] = [0]) -> AgentWork.Place {
    var place = AgentWork.Place(kind: .file, name: name)
    place.reads = reads
    place.edits = edits
    place.agents = agents
    return place
}

private func work(_ places: [AgentWork.Place]) -> AgentWork {
    var work = AgentWork()
    work.places = places
    return work
}

/// Folders first, then files, by name; a folder with one folder in it shows as one; a worktree's own folder touched
/// as a whole counts as searching the project, not as a file at its root.
@Test func theProjectTreeSortsAndMergesItsFolders() {
    var root = AgentWork.Place(kind: .file, name: ".")
    root.worktree = "fix"
    let tree = WorkTree.project(
        work([
            file("Sources/Daemon/Sessions/b.swift"), file("Sources/Daemon/Sessions/a.swift", edits: 1),
            file("Sources/Core/x.swift"), file("README.md"), root, AgentWork.Place(kind: .folder, name: "Tests")
        ]), rootName: "Kelp")
    #expect(tree.place == nil && tree.searched)
    #expect(tree.children.map(\.name) == ["Sources", "Tests", "README.md"])
    let sources = tree.children[0]
    #expect(sources.children.map(\.name) == ["Core", "Daemon/Sessions"])
    #expect(sources.children[1].children.map(\.name) == ["a.swift", "b.swift"])
    #expect(sources.edited && !sources.children[0].edited)
    #expect(tree.weight == 5)   // four files and the searched Tests
    #expect(WorkTree.project(work([file("a.swift", agents: [1])]), rootName: "K", agents: [0]).children.isEmpty)
    // A path touched as a file and as a folder (`ls Daemon`, then a file in it) is a folder with its files.
    let both = WorkTree.project(work([file("Daemon"), file("Daemon/A.swift"), file("Daemon/B.swift")]), rootName: "K")
    #expect(both.children.first.map { !$0.isFile && $0.files.count == 2 } == true)
}

/// A block is as wide as the files under it, not as often as they were read; siblings too narrow to see merge into one
/// block at the end.
@Test func theLayersAreAsWideAsTheFilesUnderThem() {
    let many = (0..<40).map { file("Lib/f\($0).swift") }
    let tree = WorkTree.project(work([file("App/a.swift", reads: 50), file("App/b.swift")] + many), rootName: "K")
    let blocks = Icicle.layout(tree, width: 420, rows: 3, row: .init(height: 22, gap: 2), narrowest: 4)
    let app = blocks.first { $0.path == "App" }, lib = blocks.first { $0.path == "Lib" }
    #expect(app?.rect.width == 20)   // 2 of 42 files, however often a.swift was read
    #expect(lib?.rect.width == 400)
    #expect(blocks.filter { $0.depth == 2 && $0.path != nil }.count == 42)   // 10 pt each
    // Narrower than that, each folder's files become one block at its end.
    let narrow = Icicle.layout(tree, width: 420, rows: 3, row: .init(height: 22, gap: 2), narrowest: 11)
    #expect(narrow.filter { $0.merged > 0 }.map(\.merged) == [2, 40])
    #expect(!narrow.contains { $0.depth == 2 && $0.path != nil })
}

/// The Map folds a big tree: an edited file always shows, a folder only read from is one node until opened, an edited
/// folder keeps its edits and a couple of reads, and a folder with one file is that file.
@Test func theMapFoldsWhatWasOnlyRead() {
    let places =
        [file("Sources/Kit/edit.swift", edits: 1)] + (0..<6).map { file("Sources/Kit/r\($0).swift") }
        + (0..<5).map { file("Sources/Other/o\($0).swift") } + [file("Tests/Only/OnlyTests.swift")]
    let tree = WorkTree.project(work(places), rootName: "K")
    let nodes = NodeTree.nodes(project: tree, outside: [], opened: [])
    #expect(nodes.contains { $0.id == "Sources/Kit/edit.swift" && $0.edited })
    #expect(nodes.first { $0.id == "Sources/Other" }?.kind == .folded)
    #expect(nodes.first { $0.kind == .more && $0.parent == "Sources/Kit" }?.label == "+ 4 read")
    // The folders Tests/Only, merged, then one file.
    #expect(nodes.first { $0.id == "Tests/Only/OnlyTests.swift" }?.prefix == "Tests/Only/")
    let opened = NodeTree.nodes(project: tree, outside: [], opened: ["Sources/Other", "Sources/Kit"])
    #expect(opened.filter { $0.parent == "Sources/Other" }.count == 5)
    #expect(!opened.contains { $0.kind == .more })
    // Past the budget, every read-only folder folds and edited folders keep only their edits.
    let big = WorkTree.project(work(places + (0..<60).map { file("Docs/d\($0).md") }), rootName: "K")
    let folded = NodeTree.nodes(project: big, outside: [], opened: [], budget: 5)
    #expect(folded.first { $0.id == "Docs" }?.kind == .folded)
    #expect(folded.filter { $0.kind == .file && !$0.edited && $0.parent == "Sources/Kit" }.isEmpty)
}

/// A parent sits in the middle of its children, leaves one step apart, and the outside after the project.
@Test func theMapLaysOutLeavesAndParents() {
    var site = AgentWork.Place(kind: .web, name: "example.com")
    site.agents = [0]
    let tree = WorkTree.project(
        work([file("A/a.swift"), file("A/b.swift"), file("A/c.swift"), file("A/d.swift")]), rootName: "K")
    let nodes = NodeTree.nodes(project: tree, outside: [site], opened: ["A"])
    let at = NodeTree.layout(nodes, width: { _ in 50 }, step: 20, gap: 10)
    let leaves = ["A/a.swift", "A/b.swift", "A/c.swift", "A/d.swift"].compactMap { at[$0]?.y }
    #expect(leaves == [0, 20, 40, 60])
    #expect(at["A"]?.y == 30)
    #expect((at[NodeTree.outsideId(site)]?.y ?? 0) > 60)
    #expect((at["A"]?.x ?? 0) > (at[NodeTree.projectId]?.x ?? 0))
    // A project folder named like the map's own nodes is a folder of its own.
    let named = WorkTree.project(
        work([file("agent/a.swift"), file("project/b.swift"), file("outside/c.swift")]), rootName: "K")
    let clash = NodeTree.layout(
        NodeTree.nodes(project: named, outside: [site], opened: ["agent", "project", "outside"]), width: { _ in 50 },
        step: 20, gap: 10)
    #expect(
        ["agent/a.swift", "project/b.swift", "outside/c.swift", NodeTree.outsideId(site)].allSatisfy {
            clash[$0] != nil
        })
}

/// Steps fold an agent's reads in a row; a subagent gets a lane where it was started and gives it back when it
/// reports.
@Test func stepsFoldReadsAndGiveSubagentsALane() {
    let t = Date(timeIntervalSince1970: 0)
    func step(_ agent: Int, _ kind: AgentWork.Step.Kind, _ detail: String = "", other: Int? = nil) -> AgentWork.Step {
        var step = AgentWork.Step(agent: agent, kind: kind, tool: "", detail: detail, at: t)
        step.other = other
        return step
    }
    let rows = StepRow.make(
        [
            step(0, .read, "a.swift"), step(0, .read, "b.swift"), step(0, .spawn, other: 1), step(1, .read, "c.swift"),
            step(0, .edit, "a.swift"), step(1, .report, other: 0), step(0, .command)
        ], filter: nil)
    #expect(rows.map(\.count) == [2, 1, 1, 1, 1, 1])
    #expect(rows[0].step.detail == "a.swift, b.swift")
    #expect(rows[1].lane == 1 && rows[1].link == 0 && rows[1].after == [0, 1])
    #expect(rows[2].lane == 1)
    #expect(rows[4].lane == 1 && rows[4].after == [0])
    #expect(StepRow.make([step(0, .read), step(1, .read)], filter: [1]).count == 1)
    // Folded, a subagent is the one row that started it, with its steps counted there and no lane of its own.
    let folded = StepRow.make(
        [
            step(0, .spawn, other: 1), step(1, .read, "c"), step(1, .edit, "c"), step(1, .report, other: 0),
            step(0, .edit)
        ],
        filter: nil, folded: [1])
    #expect(folded.map(\.step.kind) == [.spawn, .edit] && folded[0].inside == 2 && folded[0].lane == 0)
    #expect(folded.allSatisfy { $0.before.union($0.after) == [0] })
    // One it started is folded onto the same row: its steps count there too.
    let nested = StepRow.make(
        [step(0, .spawn, other: 1), step(1, .spawn, other: 2), step(2, .read, "x"), step(2, .edit, "x")],
        filter: nil, folded: [1, 2])
    #expect(nested.count == 1 && nested[0].inside == 3)
    // Shown unfolded, a parent's lane waits for its child's report, though its own last step came before.
    let waits = StepRow.make(
        [step(0, .spawn, other: 1), step(1, .spawn, other: 2), step(2, .read, "x"), step(2, .report, other: 1)],
        filter: nil)
    #expect(waits[2].before.contains(waits[0].lane) && waits[3].before.contains(waits[0].lane))
    // A subagent that never reports gives its lane back after its last step; past five lanes, agents share the last.
    let quiet = StepRow.make([step(0, .spawn, other: 1), step(1, .read, "x"), step(0, .edit, "y")], filter: nil)
    #expect(quiet[1].after == [0] && quiet[2].before == [0])
    let many = StepRow.make(
        (1...12).flatMap { [step(0, .spawn, other: $0), step($0, .read, "f\($0)")] } + [step(0, .command)], filter: nil)
    #expect(many.allSatisfy { $0.lane < StepRow.maxLanes })
    let crowded = StepRow.make(
        (1...12).map { step(0, .spawn, other: $0) } + (1...12).map { step($0, .edit, "f\($0)") }, filter: nil)
    #expect(crowded.allSatisfy { $0.lane < StepRow.maxLanes && $0.before.count <= StepRow.maxLanes })
}

/// The card under the pointer is as wide as its words (up to its width), not squeezed to the narrowest they allow.
@MainActor @Test func aNodesCardIsAsWideAsItsWords() {
    var place = AgentWork.Place(kind: .tool, name: "claude-in-chrome")
    place.reads = 2
    place.detail = "javascript_tool"
    place.agents = [0]
    let card = WorkCard(place: place, names: ["Claude Code"], icons: [nil]) { _ in }
    card.loadView()
    let width = card.view.fittingSize.width
    #expect(width > 150)
    #expect(width <= 300)
}

/// The picker lists a kind of subagent once, and names a pick by who it is, so a subagent that appears later (its file
/// sorting first) leaves the pick where it was.
@MainActor @Test func thePickerGroupsSubagentsAndKeepsItsPick() {
    func agent(_ name: String, _ id: String) -> AgentWork.Agent {
        .init(role: .subagent, agent: "claude", name: name, id: id)
    }
    var work = AgentWork()
    work.agents = [
        .init(role: .main, agent: "claude", name: "claude"), agent("Explore", "b"), agent("Plan", "c"),
        agent("Explore", "d")
    ]
    work.places = [file("a.swift", agents: [0, 1, 2, 3])]
    let names = work.agents.map(\.name)
    let entries = AgentPicker.entries(work, names: names)
    #expect(entries.map(\.label) == ["claude", "Explore ×2", "Plan"])
    let plan = entries[2].key
    work.agents.insert(agent("Review", "a"), at: 1)
    work.places = [file("a.swift", agents: [0, 1, 2, 3, 4])]
    let later = AgentPicker.entries(work, names: work.agents.map(\.name))
    #expect(later.first { $0.key == plan }?.members == [3])
}

/// The summary counts files by path, as the map draws them: one file read in two worktrees is one; the counts come
/// before the prompt, so a narrow panel cuts the prompt.
@Test func theSummaryCountsFilesByPath() {
    var inTree = file("Sources/a.swift", edits: 1)
    inTree.worktree = "agent-a1"
    var turn = work([file("Sources/a.swift"), inTree, file("Sources/b.swift")])
    turn.turns = [.init(prompt: "fix it", at: Date())]
    #expect(WorkSummary.line(turn, turn: 0) == "2 files · 1 edited · «fix it»")
}

/// The panel and the Map tab showing one session share a read until its files change; a failed read isn't kept.
@MainActor @Test func oneReadServesThePanelAndTheTab() async {
    let choices = WorkChoices()
    var made = 0
    func ask(_ stamp: String, fails: Bool = false) async -> AgentWork? {
        await choices.read(SessionWork(id: "s1"), stamp: stamp) {
            made += 1
            return fails ? (nil, "no host") : (AgentWork(), nil)
        }.value.0
    }
    _ = await ask("a")
    _ = await ask("a")
    #expect(made == 1)
    _ = await ask("b")
    #expect(made == 2)
    _ = await ask("c", fails: true)
    _ = await ask("c")
    #expect(made == 4)
}
