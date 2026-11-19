import Core
import Foundation
import Testing

@testable import Daemon

/// The library's index comes from settings' `extensions.library` when set (a team's own, a fork being tried); a
/// source that isn't a GitHub folder is refused before anything is downloaded.
@Test func theLibraryIsReadFromItsIndex() async throws {
    let (d, c, root) = try daemon()
    defer { d.stop() }
    let index = root.appendingPathComponent("index.json")
    try
        #"[{"id": "docker", "name": "Docker", "version": "1.0.0", "requires": ["docker"], "source": "https://github.com/me/exts/tree/abc/extensions/docker"}]"#
        .write(to: index, atomically: true, encoding: .utf8)
    _ = try await c.call(SettingsSet(key: "extensions.library", value: .string(index.absoluteString)))
    let all = try await c.call(ExtensionLibrary())
    #expect(all.map(\.id) == ["docker"] && all.first?.requires == ["docker"] && all.first?.description == nil)
    #expect(all.first?.category == nil)   // an index from before categories still reads
    // The library's search and `kelp ext search`: every word, anywhere in the id, name, description or category.
    let icons = try JSONDecoder().decode(
        ExtensionLibrary.Entry.self,
        from: Data(
            #"""
            {"id": "tidepool-icons", "name": "Tidepool Icons", "version": "1.0.0", "description": "File icons, a tag per language",
             "category": "icons", "source": "https://github.com/me/exts/tree/abc/extensions/tidepool-icons"}
            """#.utf8))
    #expect(icons.matches("") && icons.matches("ICONS tag") && icons.matches("tidepool") && !icons.matches("docker"))

    _ = try await c.call(SettingsSet(key: "extensions.library", value: .string("-o/etc/x")))   // never handed to curl
    let refused = await #expect(throws: RPCError.self) { try await c.call(ExtensionLibrary()) }
    #expect(refused?.message.contains("must be an https URL") == true, "\(String(describing: refused))")
    _ = try await c.call(
        SettingsSet(key: "extensions.library", value: .string(root.appendingPathComponent("gone.json").absoluteString)))
    await #expect(throws: RPCError.self) { try await c.call(ExtensionLibrary()) }
    for bad in ["docker", "https://example.com/a/b/c", "me/exts/tree/main/../../etc"] {
        await expectRefusal(says: "Not a GitHub folder", "\(bad)") { try await c.call(ExtensionFetch(source: bad)) }
    }
}
