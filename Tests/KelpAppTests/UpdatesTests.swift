import Foundation
import Testing

@testable import KelpApp
@testable import KelpKit

@MainActor private func updates() throws -> Updates {
    let suite = "updates-\(UUID().uuidString)"
    return Updates(defaults: try #require(UserDefaults(suiteName: suite)))
}

/// A download offers itself once it's on disk, and the click is what installs it.
@MainActor @Test func aReadyUpdateInstallsOnTheClick() async throws {
    let u = try updates(), app = AppModel(builtins: Builtins.all)
    var installs = 0
    u.arrived(.init(version: "9.9.0", notes: nil)) { installs += 1 }
    #expect(u.ready?.version == "9.9.0" && installs == 0)
    await u.install(app)
    await u.install(app)   // again after a quit that unsaved files cancelled
    #expect(installs == 2)
}

/// The launch that is the update says so once; another version's launch keeps quiet.
@MainActor @Test func theUpdatedLaunchSaysSoOnce() throws {
    let u = try updates()
    let notes = try #require(URL(string: "https://example.com/notes"))
    u.arrived(.init(version: "9.9.0", notes: notes)) {}
    #expect(u.installed(current: "9.8.0") == nil)
    #expect(u.installed(current: "9.9.0") == .init(version: "9.9.0", notes: notes))
    #expect(u.installed(current: "9.9.0") == nil)
}
