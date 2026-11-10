import Testing

@testable import BuiltinFiles

@Test func savingNeverClobbersOrResurrects() {
    #expect(FileSync.save(buffer: "a", saved: "a", disk: .missing) == .none)
    #expect(FileSync.save(buffer: "b", saved: "a", disk: .present("a")) == .write)
    #expect(FileSync.save(buffer: "b", saved: "a", disk: .present(nil)) == .conflict(""))   // rewritten in another encoding: ask, don't overwrite
    #expect(FileSync.save(buffer: "b", saved: "a", disk: .present("agent")) == .conflict("agent"))
    #expect(FileSync.save(buffer: "b", saved: "a", disk: .missing) == .missing)   // moved or deleted: don't write it back
}

@Test func diskChangesFollowOrAsk() {
    #expect(FileSync.diskChanged(buffer: "a", saved: "a", disk: .present("agent")) == .follow("agent"))
    #expect(FileSync.diskChanged(buffer: "b", saved: "a", disk: .present("agent")) == .conflict("agent"))
    #expect(FileSync.diskChanged(buffer: "b", saved: "a", disk: .present("a")) == .none)
    #expect(FileSync.diskChanged(buffer: "a", saved: "a", disk: .missing) == .missing)
    // Rewritten as something that isn't text: ⌘S reports a conflict, so this must ask too, or ⌘S does nothing at all.
    #expect(FileSync.diskChanged(buffer: "b", saved: "a", disk: .present(nil)) == .conflict(""))
}
