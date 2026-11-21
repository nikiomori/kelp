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
@MainActor @Test func theMapAnswersThePointerAndTheKeys() {
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
    #expect(point != nil)
    if let point {
        view.mouseMoved(with: mouse(.mouseMoved, at: NSPoint(x: point.midX, y: point.midY), in: view))
        #expect(hovered?.id == target)
        shot(view, "map-hover")
    }

    var activated: MapNode?
    view.onActivate = { activated = $0 }
    if let folded = nodes.first(where: { $0.kind == .folded }),
        let rect = view.accessibilityChildren()?.compactMap({ $0 as? NSAccessibilityElement })
            .first(where: { ($0.accessibilityLabel() ?? "").hasPrefix(folded.label) })?
            .accessibilityFrameInParentSpace()
    {
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: rect.midX, y: rect.midY), in: view))
        #expect(activated?.kind == .folded)
    }

    view.selected = target
    view.keyDown(with: key(NSLeftArrowFunctionKey))
    #expect(view.selected == "Sources/Daemon/Sessions")
    view.keyDown(with: key(NSRightArrowFunctionKey))
    #expect(view.selected == nodes.first { $0.parent == "Sources/Daemon/Sessions" }?.id)
    view.keyDown(with: key(NSDownArrowFunctionKey))
    #expect(view.selected != target || nodes.filter { $0.parent == "Sources/Daemon/Sessions" }.count == 1)
    view.now = WorkMapController.visible(work.places[work.now ?? 0], in: nodes)
    #expect(view.now == "Sources/Core/Values/Models.swift" || view.now == "Sources/Core/Values")
    shot(view, "map-keys")
}

/// The layers: a click picks a block, a double click on a folder goes into it, the arrows move along a row; the chips
/// row shows what fits and drops the rest.
@MainActor @Test func theLayersAnswerThePointerAndTheKeys() {
    let work = sampleWork()
    let tree = WorkTree.project(work, rootName: "Kelp")
    let icicle = IcicleView(frame: NSRect(x: 0, y: 0, width: 356, height: 118))
    icicle.root = tree
    let holder = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
    holder.addSubview(icicle)
    icicle.frame.origin = NSPoint(x: 12, y: 90)
    let chips = OutsideChips(frame: NSRect(x: 12, y: 40, width: 356, height: 22))
    holder.addSubview(chips)
    chips.show(WorkTree.outside(work))
    let win = window(holder, holder.frame.size)
    _ = win
    holder.layoutSubtreeIfNeeded()
    icicle.layout()
    var picked: String?, zoomed: String??
    icicle.onSelect = { picked = $0 }
    icicle.onZoom = { zoomed = .some($0) }
    let blocks = Icicle.layout(
        tree, width: icicle.bounds.width, rows: IcicleView.rows,
        row: .init(height: TextSize.of(Metrics.row) - Metrics.lineGap, gap: Metrics.lineGap),
        narrowest: Metrics.gapTight)
    let sources = blocks.first { $0.path == "Sources" }
    #expect(sources != nil)
    if let sources {
        let at = NSPoint(x: sources.rect.midX, y: sources.rect.midY)
        icicle.mouseDown(with: mouse(.leftMouseDown, at: at, in: icicle))
        #expect(picked == "Sources")
        icicle.mouseDown(with: mouse(.leftMouseDown, at: at, in: icicle, clicks: 2))
        #expect(zoomed == .some("Sources"))
    }
    icicle.selected = "Sources"
    icicle.keyDown(with: key(NSRightArrowFunctionKey))
    #expect(picked == "Tests/DaemonTests")   // one folder in Tests: the chain is one block
    shot(holder, "layers")
    // The chips that fit show whole; the rest are dropped, not squeezed.
    let shown = chips.subviews.first?.subviews.filter { !$0.isHidden && $0.frame.width > 0 } ?? []
    #expect(!shown.isEmpty)
    for chip in shown { #expect(chip.frame.maxX <= chips.bounds.width + 0.5) }
    // What didn't fit is counted, the agent's own folders with it.
    let chipCount = shown.filter { !($0 is NSTextField) && $0.subviews.count > 0 }.count
    let more = shown.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("+") }
    #expect(more?.stringValue == "+ \(8 - chipCount) more")
}

/// The steps list draws every kind of step on its lanes.
@MainActor @Test func theStepsListDrawsEveryKind() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    let work = sampleWork()
    let steps = StepsList()
    steps.scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
    steps.table.tableColumns.first?.width = 380
    let win = window(steps.scroll, steps.scroll.frame.size)
    _ = win
    steps.show(work, names: ["claude", "Explore"], app: rig.app, filter: nil)
    #expect(steps.table.numberOfRows == 10)   // the subagent's two reads of one file are one row
    shot(steps.scroll, "steps")
    let files = WorkFileList()
    files.scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 160)
    let win2 = window(files.scroll, files.scroll.frame.size)
    _ = win2
    files.show(
        WorkTree.project(work, rootName: "Kelp"), names: ["claude", "Explore"], app: rig.app, agents: work.agents)
    #expect(files.table.numberOfRows == 34)
    shot(files.scroll, "files")
}
