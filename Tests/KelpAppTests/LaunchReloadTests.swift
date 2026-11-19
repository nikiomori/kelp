import Core
import Foundation
import TestSupport
import Testing

@testable import KelpKit

extension OneAtATime {
    /// Launch loads the extensions twice: before the daemon (the window is made of them) and once its state and settings
    /// are in. Not again for settings.json's own list of switched-off ones, the first answer that a required tool is
    /// there, or a first trust record with nothing in it to adopt.
    @Test func launchLoadsTheExtensionsTwice() async throws {
        let rig = try await AppRig(files: [:])
        defer { rig.done() }
        let folder = ExtensionRegistry.userDir.appendingPathComponent("t-launch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"id":"t.launch","name":"L","requires":["sh"],"contributes":{}}"#.write(
            to: folder.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
        _ = try await rig.client.call(SettingsSet(key: SettingKeys.disabledExtensions.key, value: .array([])))
        let reg = rig.app.extensions, key = SettingKeys.disabledExtensions.key
        #expect(try await waitFor(5) { rig.app.settings.values[key] != nil })   // its event
        rig.app.settings.apply([:])   // as at launch: not read yet
        await mainActorTurns()
        reg.reload()   // applicationDidFinishLaunching's
        await rig.app.opened(rig.client)
        #expect(try await waitFor(10) { reg.tools["sh"] == true })
        // The first trust record (`ExtensionTrust.adopt`) is saved, and its answer comes before the answer to a call
        // made after it (both answered in order): what adopt does with it has run by then.
        #expect(try await waitFor(5) { rig.app.uiState[ExtensionFiles.extensionTrustKey] != nil })
        _ = try await rig.client.call(ClientEvents(events: true))
        await mainActorTurns()
        #expect(reg.revision == 2)
        #expect(reg.disabledLoaded.isEmpty)   // settings.json's list was loaded all the same
    }
}
