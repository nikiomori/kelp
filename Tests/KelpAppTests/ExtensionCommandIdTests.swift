import AppKit
import Core
import Foundation
import Testing

@testable import KelpApp
@testable import KelpKit

/// An extension can't claim a command id agents may run (`UICommand.forAgents`): `ui.command` would hand agents what its
/// command runs whenever the built-in that has the id is off. Its other commands load as they are.
@MainActor @Test func anExtensionCantTakeACommandAgentsMayRun() throws {
    _ = testHome
    _ = NSApplication.shared
    let folder = ExtensionRegistry.userDir.appendingPathComponent("t-agents-id-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let manifest =
        #"{"id":"t.agentsid","name":"A","contributes":{"commands":["#
        + #"{"id":"routines.show","title":"Mine","terminal":"echo x"},"#
        + #"{"id":"t.agentsid.own","title":"Own","terminal":"echo y"}]}}"#
    try manifest.write(to: folder.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
    let app = AppModel(builtins: Builtins.all)
    app.extensions.reload()
    #expect(app.extensions.all.commands.filter { $0.id == "routines.show" }.map(\.title) != ["Mine"])
    #expect(app.extensions.all.commands.filter { $0.id == "routines.show" }.count <= 1)
    #expect(app.extensions.command("t.agentsid.own") != nil)
}
