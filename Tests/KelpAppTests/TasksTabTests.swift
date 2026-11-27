import AppKit
import Carbon
import Core
import Foundation
import TestSupport
import Testing

@testable import BuiltinTasks
@testable import KelpKit

/// The Tasks tab over a real daemon: lines written through it land on the project's list, the tab reads them back
/// through the project's watch, a chat's work moves a line into Now (its question first), the board puts each line in
/// its column, and Quick Entry offers the list's headings. With KELP_SHOT set it writes pictures of the list, the
/// board, the page a task grew into and Quick Entry (windows a test draws stay unseen).
@MainActor @Test func theTasksTabGathersAProjectsLines() async throws {
    let rig = try await AppRig()
    defer { rig.done() }
    let app = rig.app, repo = rig.project.id
    let names = TaskListNames(title: "Tasks", inbox: "Inbox")
    func add(_ text: String, under: String? = nil, issue: String? = nil, chat: String? = nil) async throws
        -> TaskAdd.Result
    {
        try await rig.client.call(
            TaskAdd(repoId: repo, under: under, text: text, issue: issue, chat: chat, names: names))
    }
    _ = try await add("Dark diff theme #design")
    _ = try await add("Ru dates in CI Runs", issue: "https://github.com/o/r/issues/212")
    let inset = try await add("Fix the inset in the limits card", under: "Now", chat: "c-work")
    _ = try await add("Push notifications on the phone", under: "Now", chat: "c-asks")
    let search = try await add("Search the chats' history", under: "Now")
    let grown = try #require(
        try await rig.client.call(
            TaskChange(path: search.path, task: TaskRef(search.task), grow: "Plan", goalLabel: "Done when")))
    let page = URL(fileURLWithPath: search.path).deletingLastPathComponent()
        .appendingPathComponent(try #require(grown.page)).standardizedFileURL.path
    _ = try await rig.client.call(TaskAdd(repoId: repo, path: page, under: "Plan", text: "Index the transcripts"))
    let ollama = try await add("Ollama and llama.cpp", under: "Later")
    _ = try await rig.client.call(TaskChange(path: ollama.path, task: TaskRef(ollama.task), state: .done))
    #expect(inset.task.chats == ["c-work"])

    for (id, status, title) in [
        ("c-work", AgentStatus.working, "Inset"), ("c-asks", .waiting, "Wake the phone")
    ] {
        var chat = Session(id: id, worktreeId: rig.workspace.id, cwd: rig.repo, command: "claude")
        chat.agent = Session.claudeAgent
        chat.status = status
        chat.title = title
        app.sessions.append(chat)
    }

    let controller = TasksController(model: TasksModel(app: app))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled], backing: .buffered,
        defer: true)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = controller.view
    controller.viewDidAppear()
    let model = controller.model
    model.source = .all
    #expect(try await waitFor(10) { model.rows.count == 7 })

    // All: the open tasks, by project and place; the step under the grown page is its page's.
    let all = TaskViews.sections(model.rows, .all, projectName: model.projectName, day: { _ in "" })
    #expect(all.flatMap(\.rows).count == 6)
    #expect(all.map(\.title).contains { $0.hasSuffix("› Search the chats' history › Plan") })
    // Now: the question first, then the work.
    model.source = .now
    let now = TaskViews.sections(model.rows, .now, day: { _ in "" })
    #expect(
        now.map { $0.rows.map(\.task.title) } == [
            ["Push notifications on the phone"], ["Fix the inset in the limits card"]
        ])
    #expect(TaskViews.counts(model.rows, [.inbox, .waiting, .journal]) == [.inbox: 2, .waiting: 1, .journal: 1])
    // The board: each task in its column, worked out.
    let board = Dictionary(
        uniqueKeysWithValues: TaskViews.board(model.rows, .all, inPR: { _ in false }).map {
            ($0.column, $0.rows.map(\.task.title))
        })
    #expect(board[.working] == ["Push notifications on the phone", "Fix the inset in the limits card"])
    #expect(board[.plan] == ["Search the chats' history"])
    #expect(board[.done] == ["Ollama and llama.cpp"])
    // The grown page's goal is read from its line; Quick Entry offers the list's headings.
    #expect(
        try await waitFor(10) {
            app.latest(TasksEvent.self, repo)?.pages.contains { $0.title == "Search the chats' history" } == true
        })

    guard let dir = ProcessInfo.processInfo.environment["KELP_SHOT"] else { return }
    model.source = .now
    try await shootTasks(controller.view, window, "tasks-now", dir)
    model.source = .all
    try await shootTasks(controller.view, window, "tasks-all", dir)
    model.board = true
    try await shootTasks(controller.view, window, "tasks-board", dir)
    model.board = false
    let entry = QuickEntry.shared(app)
    entry.show(repo: repo)
    if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }), let view = panel.contentView {
        try await shootTasks(view, panel, "tasks-quick-entry", dir)
        panel.orderOut(nil)
    }
}

/// Writes a picture of `view` once it is laid out.
@MainActor private func shootTasks(_ view: NSView, _ window: NSWindow, _ name: String, _ dir: String) async throws {
    for _ in 0..<4 {
        await mainActorTurns()
        view.layoutSubtreeIfNeeded()
    }
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    withExtendedLifetime(window) {}
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}

extension OneAtATime {
    // A hot key and a key window are the process's own: one at a time.
    /// Quick Entry's hot key (⌃⌥⌘T, which macOS leaves free, unlike ⌃⌥Space, its next input source) opens the panel.
    @Test func theHotKeyOpensQuickEntry() async throws {
        let app = AppModel(builtins: [])
        let entry = QuickEntry.shared(app)
        // The system's answer is noErr on a Mac with a person at it; CI's runners have no session to grant hot keys in.
        entry.registerHotKey()
        defer { entry.unregisterHotKey() }
        var event: EventRef?
        CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone),
            &event)
        var id = EventHotKeyID(signature: QuickEntry.signature, id: 1)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &id)
        SendEventToEventTarget(event, GetApplicationEventTarget())
        #expect(try await waitFor(5) { NSApp.windows.contains { $0 is NSPanel && $0.isVisible } })
        // Leaves no field of the panel in the responder chain: a later test's Find would go to it.
        for panel in NSApp.windows where panel is NSPanel {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
        }
    }
}
