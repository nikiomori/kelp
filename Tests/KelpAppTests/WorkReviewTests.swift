import AppKit
import Core
import DesignKit
import Foundation
import Testing

@testable import BuiltinWork

// The Work panel's and the Map tab's views driven as a person drives them: real pointer and key events in a window,
// with what changes checked, and a picture of each state written to KELP_SHOT when it's set.

@MainActor private func shot(_ view: NSView, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["KELP_SHOT"] else { return }
    view.layoutSubtreeIfNeeded()
    view.display()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let picture = NSImage(size: view.bounds.size)
    picture.lockFocus()
    NSColor.textBackgroundColor.setFill()
    view.bounds.fill()
    rep.draw(in: view.bounds)
    picture.unlockFocus()
    let png = picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(
        using: .png, properties: [:])
    try? png?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}

@MainActor private func window(_ view: NSView, _ size: NSSize) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(
        named: ProcessInfo.processInfo.environment["KELP_SHOT_DARK"] == nil ? .aqua : .darkAqua)
    window.contentView = view
    window.layoutIfNeeded()
    return window
}

@MainActor private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent
{
    NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}

@MainActor private func key(_ special: Int) -> NSEvent {
    let text = String(Character(UnicodeScalar(special)!))
    return NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: text,
        charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
}

/// A turn like a real one: files edited in a worktree and read by a subagent, a big read-only sweep, and every kind of
/// place outside.
private func sampleWork() -> AgentWork {
    func file(
        _ name: String, reads: Int = 1, edits: Int = 0, add: Int = 0, rem: Int = 0, agents: [Int] = [0],
        worktree: String? = nil
    )
        -> AgentWork.Place
    {
        var place = AgentWork.Place(kind: .file, name: name)
        (place.reads, place.edits, place.added, place.removed, place.agents, place.worktree) = (
            reads, edits, add, rem, agents, worktree
        )
        return place
    }
    func outside(_ kind: AgentWork.Kind, _ name: String, _ detail: String) -> AgentWork.Place {
        var place = AgentWork.Place(kind: kind, name: name)
        place.reads = 1
        place.detail = detail
        place.agents = [0]
        return place
    }
    var work = AgentWork()
    work.root = "/Users/me/Kelp"
    work.turns = [AgentWork.Turn(prompt: "Fix the remote tests", at: Date(timeIntervalSince1970: 0))]
    work.turn = 0
    work.agents = [
        .init(role: .main, agent: "claude", name: "claude"), .init(role: .subagent, agent: "claude", name: "Explore")
    ]
    work.places =
        [
            file("Sources/Daemon/Sessions/ChildReports.swift", reads: 2, edits: 2, add: 96, rem: 30, agents: [0]),
            file("Sources/Daemon/Sessions/LaunchHandlers.swift", edits: 1, add: 12, rem: 3, worktree: "fix"),
            file("Sources/Core/Values/Models.swift", reads: 9, edits: 1, add: 2, agents: [0, 1]),
            file("Tests/DaemonTests/RemoteAgentsTests.swift", edits: 1, add: 24, rem: 4)
        ] + (0..<6).flatMap { f in (0..<5).map { n in file("Sources/Builtins/B\(f)/File\(n).swift", agents: [1]) } } + [
            outside(.web, "127.0.0.1:8765", "curl"), outside(.web, "github.com", "gh pr view"),
            outside(.web, "code.claude.com", "fetch"), outside(.machine, "mini.local", "ssh"),
            outside(.tool, "claude-in-chrome", "navigate"), outside(.packages, "Homebrew", "brew install"),
            outside(.outside, "~/projects/fixtures", ""), outside(.own, "/tmp", "")
        ]
    let t = Date(timeIntervalSince1970: 0)
    func step(_ agent: Int, _ kind: AgentWork.Step.Kind, _ detail: String, other: Int? = nil) -> AgentWork.Step {
        var step = AgentWork.Step(agent: agent, kind: kind, tool: "", detail: detail, at: t)
        step.other = other
        return step
    }
    work.steps = [
        step(0, .read, "Sources/Daemon/Sessions/ChildReports.swift"),
        step(0, .search, "remoteAgents in Sources/Daemon"),
        step(0, .spawn, "find transcript readers", other: 1), step(1, .read, "Sources/Core/Values/Models.swift"),
        step(1, .read, "Sources/Core/Values/Models.swift"), step(1, .web, "code.claude.com"),
        step(1, .report, "", other: 0), step(0, .edit, "Sources/Daemon/Sessions/ChildReports.swift"),
        step(0, .failed, "swift test --filter RemoteAgents"), step(0, .ask, "Run git push?"),
        step(0, .command, "ssh niko@mini.local 'swift test'")
    ]
    work.now = 2
    return work
}

/// The Map: the pointer on a file lights its path to the agent; a click on a folded folder asks to open it; the arrows
/// walk the tree; where the agent is now is ringed on the node that stands for it.
@MainActor @Test func theMapAnswersThePointerAndTheKeys() throws {
    let work = sampleWork()
    let project = WorkTree.project(work, rootName: "Kelp")
    let view = WorkMapView()
    view.names = ["claude", "Explore"]
    view.icons = [nil, nil]
    let nodes = NodeTree.nodes(project: project, outside: WorkTree.outside(work), opened: [])
    view.nodes = nodes
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
    scroll.documentView = view
    let win = window(scroll, scroll.frame.size)
    _ = win
    shot(view, "map")
    #expect(nodes.contains { $0.kind == .folded })
    #expect(!nodes.contains { $0.kind == .file && $0.id.hasPrefix("Sources/Builtins") })

    var hovered: MapNode?
    view.onHover = { node, _ in hovered = node }
    let target = "Sources/Daemon/Sessions/ChildReports.swift"
    let point = view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }
        .first { ($0.accessibilityLabel() ?? "").hasPrefix("ChildReports.swift") }?.accessibilityFrameInParentSpace()
    let at = try #require(point)
    view.mouseMoved(with: mouse(.mouseMoved, at: NSPoint(x: at.midX, y: at.midY), in: view))
    #expect(hovered?.id == target)
    shot(view, "map-hover")

    var activated: MapNode?
    view.onActivate = { activated = $0 }
    let folded = try #require(nodes.first { $0.kind == .folded })
    let rect = try #require(
        view.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityElement })
            .first(where: { ($0.accessibilityLabel() ?? "").hasPrefix(folded.label) })?
            .accessibilityFrameInParentSpace())
    view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: rect.midX, y: rect.midY), in: view))
    #expect(activated?.kind == .folded)

    view.selected = target
    view.keyDown(with: key(NSLeftArrowFunctionKey))
    #expect(view.selected == "Sources/Daemon/Sessions")
    view.keyDown(with: key(NSRightArrowFunctionKey))
    #expect(view.selected == nodes.first { $0.parent == "Sources/Daemon/Sessions" }?.id)
    let siblings = nodes.filter { $0.parent == "Sources/Daemon/Sessions" }.map(\.id)
    #expect(siblings.count > 1)
    view.keyDown(with: key(NSDownArrowFunctionKey))
    #expect(view.selected == siblings[1])
    // Where the agent is now: its file's node, or the folded folder it is in.
    let now = work.places[try #require(work.now)].name
    view.now = WorkMapController.visible(work.places[try #require(work.now)], in: nodes)
    let shown = try #require(view.now)
    #expect(nodes.contains { $0.id == shown } && (shown == now || Paths.relative(now, to: shown) != nil))
    shot(view, "map-keys")
}

/// The layers: a click picks a block, a double click on a folder goes into it, the arrows move along a row; the chips
/// row shows what fits and drops the rest.
@MainActor @Test func theLayersAnswerThePointerAndTheKeys() throws {
    let work = sampleWork()
    let tree = WorkTree.project(work, rootName: "Kelp")
    let icicle = IcicleView(frame: NSRect(x: 0, y: 0, width: 356, height: 118))
    icicle.root = tree
    let holder = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
    holder.addSubview(icicle)
    icicle.frame.origin = NSPoint(x: 12, y: 90)
    let chips = OutsideChips(frame: NSRect(x: 12, y: 40, width: 356, height: 74))
    holder.addSubview(chips)
    chips.show(WorkTree.outside(work))
    let win = window(holder, holder.frame.size)
    _ = win
    holder.layoutSubtreeIfNeeded()
    icicle.layout()
    var picked: String?, zoomed: String??
    icicle.onSelect = { picked = $0 }
    icicle.onZoom = { zoomed = .some($0) }
    // The root isn't a row: its folders are the top one.
    let sources = try #require(icicle.blocks.first { $0.path == "Sources" })
    #expect(sources.depth == 0 && sources.rect.minY == 0)
    #expect(!icicle.blocks.contains { $0.path == "" })
    let at = NSPoint(x: sources.rect.midX, y: sources.rect.midY)
    icicle.mouseDown(with: mouse(.leftMouseDown, at: at, in: icicle))
    #expect(picked == "Sources")
    icicle.mouseDown(with: mouse(.leftMouseDown, at: at, in: icicle, clicks: 2))
    #expect(zoomed == .some("Sources"))
    // With nothing picked the keys start at the first named block, never a merged "…".
    icicle.selected = nil
    picked = nil
    icicle.keyDown(with: key(NSRightArrowFunctionKey))
    #expect(picked.map { path in icicle.blocks.contains { $0.path == path } } == true)
    icicle.selected = "Sources"
    icicle.keyDown(with: key(NSRightArrowFunctionKey))
    #expect(picked == "Tests/DaemonTests")   // one folder in Tests: the chain is one block
    shot(holder, "layers")
    // The chips wrap into rows and show whole, inside the panel; what is left is "+ …", a button for a menu of it.
    chips.layout()
    let shown = chips.subviews.filter { !$0.isHidden && !($0 is TextButton) }
    #expect(!shown.isEmpty)
    for chip in shown {
        #expect(chip.frame.maxX <= chips.bounds.width + 0.5 && chip.frame.width >= chip.fittingSize.width - 0.5)
        #expect(chip.frame.maxY <= chips.intrinsicContentSize.height + 0.5)
    }
    #expect(chips.hiddenCount == 8 - shown.count)
    let more = chips.subviews.compactMap { $0 as? TextButton }.first
    #expect(more?.isHidden == (chips.hiddenCount == 0))
    #expect((more?.frame.maxX ?? 0) <= chips.bounds.width + 0.5)
}

/// The steps list draws every kind of step on its lanes.
@MainActor @Test func theStepsListDrawsEveryKind() async throws {
    let rig = BareApp()
    let work = sampleWork()
    let steps = StepsList()
    steps.scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
    steps.table.tableColumns.first?.width = 380
    let win = window(steps.scroll, steps.scroll.frame.size)
    _ = win
    steps.show(work, names: ["claude", "Explore"], app: rig.app, filter: nil)
    #expect(steps.table.numberOfRows == 7)   // the subagent is the one row that started it
    shot(steps.scroll, "steps")
    steps.show(work, names: ["claude", "Explore"], app: rig.app, filter: [0, 1])
    #expect(steps.table.numberOfRows == 10)   // picked, its steps show, its two reads of one file one row
    shot(steps.scroll, "steps-lanes")
    // A turn with a dozen subagents that never report back: lanes close after each one's last step.
    var crowded = work
    crowded.agents = [work.agents[0]] + (1...12).map { .init(role: .subagent, agent: "claude", name: "Explore \($0)") }
    let t = Date(timeIntervalSince1970: 0)
    crowded.steps =
        (1...12).flatMap { n -> [AgentWork.Step] in
            var spawn = AgentWork.Step(agent: 0, kind: .spawn, tool: "Task", detail: "look \(n)", at: t)
            spawn.other = n
            return [spawn, AgentWork.Step(agent: n, kind: .read, tool: "Read", detail: "Sources/F\(n).swift", at: t)]
        } + [AgentWork.Step(agent: 0, kind: .edit, tool: "Edit", detail: "Sources/App.swift", at: t)]
    let many = StepsList()
    many.scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
    let win3 = window(many.scroll, many.scroll.frame.size)
    _ = win3
    many.show(crowded, names: ["claude"] + (1...12).map { "Explore \($0)" }, app: rig.app, filter: nil)
    shot(many.scroll, "steps-many")
    let files = WorkFileList()
    files.scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 160)
    let win2 = window(files.scroll, files.scroll.frame.size)
    _ = win2
    files.show(
        WorkTree.project(work, rootName: "Kelp"), names: ["claude", "Explore"], app: rig.app, agents: work.agents)
    #expect(files.table.numberOfRows == 34)
    shot(files.scroll, "files")
}

/// The agent picker asks for no width of its own: with three agents in 120 pt it is a menu inside its bounds, so a
/// narrow inspector keeps its width.
@MainActor @Test func theAgentPickerFitsANarrowRow() {

    let picker = AgentPicker(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
    picker.show(
        ["Claude Code", "general-purpose", "Explore"].enumerated().map { .init(key: $1, label: $1, members: [$0]) },
        picked: nil)
    picker.layout()
    let shown = picker.subviews.filter { !$0.isHidden }
    #expect(shown.count == 1 && shown.first is NSPopUpButton)
    #expect((shown.first?.frame.maxX ?? 999) <= 120.5)
}

/// The whole panel with a turn's work, in a narrow inspector and a wide one: its parts show and stay inside it.
@MainActor @Test func theWorkPanelShowsATurnAtAnyWidth() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    for (width, name) in [(280.0, "panel-narrow"), (400.0, "panel-wide")] {
        let panel = WorkPanel(app: rig.app, choices: WorkChoices())
        let win = window(panel.view, NSSize(width: width, height: 640))
        _ = win
        panel.viewDidAppear()
        panel.model.show("s1")
        panel.model.received(sampleWork())
        await Task.yield()
        panel.view.layoutSubtreeIfNeeded()
        shot(panel.view, name)
        func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
        let words = all(panel.view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        #expect(words.contains("In the project"))
        #expect(panel.view.frame.width == CGFloat(width))
    }
}

/// A turn that touched no project file but reached outside: the panel says so and shows the places.
@MainActor @Test func aTurnWithOnlyPlacesOutsideShowsThem() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    var work = sampleWork()
    work.places = work.places.filter { $0.kind != .file && $0.kind != .folder }
    let panel = WorkPanel(app: rig.app, choices: WorkChoices())
    let win = window(panel.view, NSSize(width: 280, height: 400))
    _ = win
    panel.viewDidAppear()
    panel.model.show("s1")
    panel.model.received(work)
    await Task.yield()
    panel.view.layoutSubtreeIfNeeded()
    shot(panel.view, "panel-outside-only")
    func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
    let shown = all(panel.view).filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 0 }
    #expect(shown.contains { ($0 as? NSTextField)?.stringValue == "No project files in this turn" })
    #expect(shown.contains { $0 is OutsideChips })
}

/// A file's row in a narrow panel keeps its name and lines and drops what doesn't fit whole, never a sliver; the card
/// under the pointer keeps every line inside its margins.
@MainActor @Test func aRowAndACardStayWithinTheirWidth() async throws {
    let rig = BareApp()
    var work = sampleWork()
    work.places[2].worktree = "agent-a9e8be3e7cccd0c8a"
    work.agents += (0..<5).map { _ in .init(role: .subagent, agent: "claude", name: "general-purpose") }
    work.places[2].agents = [0, 1, 2, 3, 4]
    let files = WorkFileList()
    files.scroll.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
    let win = window(files.scroll, files.scroll.frame.size)
    _ = win
    files.show(
        WorkTree.project(work, rootName: "Kelp"), names: work.agents.map(\.name), app: rig.app, agents: work.agents)
    files.scroll.layoutSubtreeIfNeeded()
    shot(files.scroll, "files-narrow")
    for row in 0..<min(files.table.numberOfRows, 6) {
        guard let cell = files.table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
        cell.layoutSubtreeIfNeeded()
        for part in cell.subviews where !part.isHidden && !(part is NSTextField && part === cell.subviews[1]) {
            #expect(part.frame.width >= part.fittingSize.width - 0.5, "squeezed in row \(row): \(type(of: part))")
            #expect(part.frame.maxX <= cell.bounds.width + 0.5)
        }
    }
    var place = work.places[2]
    place.name = "Sources/KelpKit/Shell/A/Very/Deep/Folder/MainWindow.swift"
    let card = WorkCard(place: place, names: work.agents.map(\.name), icons: []) { _ in }
    let popup = window(card.view, card.view.fittingSize)
    _ = popup
    card.view.layoutSubtreeIfNeeded()
    shot(card.view, "card")
    func all(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + all($0) } }
    for field in all(card.view).compactMap({ $0 as? NSTextField }) {
        // The text's own box (a field's frame has a little room around its text).
        let frame = field.convert(field.alignmentRect(forFrame: field.bounds), to: card.view)
        #expect(frame.minX >= Metrics.inset - 0.5 && frame.maxX <= card.view.bounds.width - Metrics.inset + 0.5)
    }
}

/// The turn menu keeps every turn, two asked the same thing in one minute included, and Whole Session last; built
/// again only when the turns change.
@MainActor @Test func theTurnMenuKeepsTurnsOfOneTitle() async throws {
    let rig = BareApp()
    let model = WorkModel(app: rig.app, choices: WorkChoices())
    let at = Date(timeIntervalSince1970: 0)
    var work = AgentWork()
    work.turns = [.init(prompt: "go on", at: at), .init(prompt: "go on", at: at), .init(prompt: "push", at: at)]
    let pop = NSPopUpButton()
    TurnMenu.fill(pop, work: work, model: model)
    #expect(pop.itemArray.filter { !$0.isSeparatorItem }.map(\.tag) == [2, 1, 0, -1])
    let first = pop.itemArray.first
    TurnMenu.fill(pop, work: work, model: model)
    #expect(pop.itemArray.first === first)
}

/// A remote session's work names the host's folder; its files open from its workspace's folder on this Mac.
@MainActor @Test func aRemoteSessionsFilesOpenFromTheFolderHere() async throws {
    let rig = BareApp()
    rig.app.sessions = [
        Session(id: "s1", worktreeId: rig.workspace.id, cwd: "/home/me/proj", command: "claude", agent: "claude")
    ]
    let model = WorkModel(app: rig.app, choices: WorkChoices())
    model.show("s1")
    var work = AgentWork()
    work.root = "/home/me/proj"
    model.received(work)
    var place = AgentWork.Place(kind: .file, name: "Sources/a.swift")
    #expect(model.path(of: place) == rig.workspace.path + "/Sources/a.swift")
    place.worktree = "fix"
    #expect(model.path(of: place) == rig.workspace.path + "/.claude/worktrees/fix/Sources/a.swift")
}

/// Show Diff for the last turn names the agent whose turn it is, as git.diff needs; an earlier turn's names its mark
/// too; a file of a worktree Kelp doesn't know has no diff to show.
@MainActor @Test func aFilesDiffNamesWhoseTurnItIs() async throws {
    let rig = BareApp()
    rig.app.sessions = [
        Session(id: "s1", worktreeId: rig.workspace.id, cwd: rig.repo, command: "claude", agent: "claude")
    ]
    let model = WorkModel(app: rig.app, choices: WorkChoices())
    model.show("s1")
    var work = AgentWork()
    work.root = rig.repo
    model.received(work)
    var place = AgentWork.Place(kind: .file, name: "a.swift")
    func items(_ uri: String?) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: (URLComponents(string: uri ?? "")?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
    }
    #expect(items(model.diffURI(place, mark: nil)) == ["file": "a.swift", "source": "turn", "session": "s1"])
    let mark = SessionTurns.Mark(id: "m1", session: "s1", tree: "t", head: nil, folder: rig.repo, prompt: "p")
    #expect(items(model.diffURI(place, mark: mark))["turn"] == "m1")
    place.worktree = "gone"
    #expect(model.diffURI(place, mark: nil) == nil)
}
