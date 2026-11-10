import Core
import Foundation
import GRDB
import Testing
import os

@testable import Daemon

@Test func storeRoundTrip() throws {
    let s = try Store()
    let r = try s.save(Repo(name: "demo", path: "/tmp/demo"))
    let w = Worktree(repoId: r.id, branch: "feat", path: "/tmp/w", note: "hi")
    try s.save(w)
    #expect(try s.repos() == [r])
    #expect(try s.worktree(w.id)?.note == "hi")
    try s.delete(r)
    #expect(try s.worktrees().isEmpty)   // cascade
}

/// Each write gives a record the next revision, however it's written: of two copies, the newer is the one with the higher.
@Test func eachWriteGivesARecordTheNextRevision() throws {
    let s = try Store()
    let r = try s.save(Repo(name: "demo", path: "/tmp/demo"))
    #expect(r.revision == 1)
    #expect(try s.update(Repo.self, r.id) { $0.name = "d" }?.revision == 2)
    var old = r
    old.name = "x"
    #expect(try s.update(old).revision == 3)   // a copy read earlier comes out newer than what was there
    #expect(try s.repo(r.id)?.revision == 3)
}

/// Two changes to one workspace at once (a rename and a PR link) both stay: neither saves back a copy read before the other.
@Test func workspaceChangesAtTheSameTimeAllStay() async throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo")
    try s.save(r)
    let w = Worktree(repoId: r.id, branch: "b", path: "/p")
    try s.save(w)
    await withTaskGroup(of: Void.self) { g in
        for i in 0..<200 {
            g.addTask {
                _ = try? s.update(Worktree.self, w.id) {
                    if i.isMultiple(of: 2) { $0.note += "n" } else { $0.prURL += "u" }
                }
            }
        }
    }
    let after = try #require(try s.worktree(w.id))
    #expect(after.note.count == 100 && after.prURL.count == 100)
}

/// A workspace's review comments go with it, also when its whole project is removed.
@Test func commentsGoWithTheirWorkspace() throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo")
    try s.save(r)
    let w = Worktree(repoId: r.id, branch: "b", path: "/p")
    try s.save(w)
    try s.save(DiffComment(worktreeId: w.id, file: "a", startLine: 1, endLine: 1, quote: "", text: "fix"))
    #expect(try s.comments(worktree: w.id).count == 1)
    try s.delete(r)   // cascades to the workspace
    #expect(try s.comments(worktree: w.id).isEmpty)
}

/// Changes are told in the order they were committed: the last one told is what the database holds. Told after the
/// write, unordered, two writers could pass each other in between and leave the app with the older record.
@Test func changesAreToldInTheOrderTheyWereCommitted() throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo")
    try s.save(r)
    let w = Worktree(repoId: r.id, branch: "b", path: "/p")
    try s.save(w)
    let committed = OSAllocatedUnfairLock<[String]>(initialState: []),
        told = OSAllocatedUnfairLock<[String]>(initialState: [])
    // A teller takes a while (the daemon's encodes and queues an event per client): a later one can't overtake.
    s.changed.withLock {
        $0.tell = { c in
            if case .worktree(let x) = c {
                usleep(.random(in: 0...1000))
                told.withLock { $0.append(x.note) }
            }
        }
    }
    let all = DispatchGroup()
    for t in 0..<8 {
        all.enter()
        Thread.detachNewThread {
            for i in 0..<50 {
                _ = try? s.update(Worktree.self, w.id) {
                    $0.note = "\(t).\(i)"
                    committed.withLock { $0.append("\(t).\(i)") }
                }
            }
            all.leave()
        }
    }
    all.wait()
    let (a, b) = (told.withLock { $0 }, committed.withLock { $0 })
    let first = a.indices.first { $0 >= b.count || a[$0] != b[$0] }   // not a diff of 400 lines
    #expect(a.count == b.count && first == nil, "told out of order from #\(first ?? -1)")
}

/// Thousands of changes told, as a daemon tells over a day of status changes: the listener stays as it was set. Held by
/// the lock as a bare function, each read wrapped it once more (in a debug build), and 3200 overflowed the stack.
@Test func aListenerToldThousandsOfChangesStaysOneCall() throws {
    let s = try Store()
    let r = Repo(name: "demo", path: "/tmp/demo")
    try s.save(r)
    let w = Worktree(repoId: r.id, branch: "b", path: "/p")
    try s.save(w)
    s.changed.withLock { $0.tell = { _ in } }
    for i in 0..<4000 { _ = try s.update(Worktree.self, w.id) { $0.note = "\(i)" } }
}

/// A read doesn't wait for a write in progress (a status change's fsync on a busy disk): reads come from connection
/// reader threads and the cooperative pool, and used to queue behind every write.
@Test func aReadDoesntWaitForAWrite() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s = try Store(path: dir.appendingPathComponent("kelp.sqlite").path)
    _ = try s.save(Repo(name: "demo", path: "/tmp/demo"))
    let inWrite = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        try? s.db.write { _ in
            inWrite.signal()
            release.wait()
        }
    }
    inWrite.wait()
    let read = DispatchSemaphore(value: 0)
    Thread.detachNewThread { if (try? s.repos().count) == 1 { read.signal() } }
    #expect(read.wait(timeout: .now() + 2) == .success)
    release.signal()
}

/// What the daemon decides by and keeps for itself is copied out of the app's state once, where any `state.set` could
/// write it: the trust as it was, the port forwardings from the JSON string they were kept in. The old rows stay for an
/// older daemon on the same store, and a stale one there doesn't win over the daemon's own.
@Test func theDaemonsOwnStateMovesOutOfTheAppsOnce() throws {
    let path = tmp().appendingPathComponent("kelp.db").path
    do {
        let old = try DatabaseQueue(path: path)
        try Store.migrator.migrate(old, upTo: "database.productionByHand")
        let forwards =
            #"[{"host":"box","target":"localhost:1","here":1,"worktree":"w","manual":true,"seen":false,"misses":0}]"#
        let rows = [
            ("lsp.trusted", #"["/p"]"#), ("extensions.trusted", #"{"x":"d"}"#),
            ("ports.forwards", String(decoding: try JSONEncoder().encode(forwards), as: UTF8.self)),
            ("sidebar.order", #"["a"]"#)
        ]
        try old.write { db in
            for (key, value) in rows {
                try db.execute(sql: "INSERT INTO uiState (key, value) VALUES (?, ?)", arguments: [key, value])
            }
        }
    }
    let s = try Store(path: path)
    #expect(try s.daemonState(LSPOpen.trustKey, as: [String].self) == ["/p"])
    #expect(try s.daemonState(ExtensionFiles.extensionTrustKey, as: [String: String].self) == ["x": "d"])
    #expect(try s.daemonState("ports.forwards", as: [Forwards.Record].self)?.map(\.here) == [1])
    #expect(
        try s.uiState(prefix: "").keys.sorted() == [
            "extensions.trusted", "lsp.trusted", "ports.forwards", "sidebar.order"
        ])
    // An older daemon's write after the copy: stale; and trust taken back since leaves none, not the old row.
    try s.setUIState(LSPOpen.trustKey, .array([.string("/stale")]))
    try s.setDaemonState(ExtensionFiles.extensionTrustKey, nil as JSONValue?)
    let ui = UIStore(store: s, clients: Clients())
    let all = try StateGet(prefix: "").handle(ui)
    #expect(all[LSPOpen.trustKey] == .array([.string("/p")]) && all[ExtensionFiles.extensionTrustKey] == nil)
    #expect(all["sidebar.order"] == .array([.string("a")]))
    #expect(try StateGet(key: LSPOpen.trustKey).handle(ui) == .array([.string("/p")]))
    #expect(try StateGet(key: ExtensionFiles.extensionTrustKey).handle(ui) == .null)
    // and the window's writes of trust go only to the daemon's table
    try StateSet(key: LSPOpen.trustKey, value: .array([.string("/q")])).handle(ui)
    #expect(try s.uiState(prefix: LSPOpen.trustKey)[LSPOpen.trustKey] == .array([.string("/stale")]))
    #expect(try s.daemonState(LSPOpen.trustKey, as: [String].self) == ["/q"])
}

/// A routine's old run whose tab is open stays, though a hidden tab lets go of its terminal: the saved layouts say.
@Test func aTabInALayoutIsFoundByItsSession() throws {
    let s = try Store()
    let tabs: JSONValue = .object([
        "groups": .object(["g": .object(["tabs": .array([.object(["uri": .string("session:abc")])])])])
    ])
    try s.setUIState("layout/w1", tabs)
    #expect(try s.inALayout("session:abc"))
    #expect(try !s.inALayout("session:ab"))   // a whole id, not its start
    try s.setUIState("sidebar.order", .array([.string("session:zzz")]))
    #expect(try !s.inALayout("session:zzz"))   // only a layout's tabs
}
