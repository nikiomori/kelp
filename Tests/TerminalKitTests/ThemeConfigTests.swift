import Foundation
import GhosttyKit
import Testing

@testable import TerminalKit

/// Kelp's look reaches Ghostty as Ghostty reads it: a see-through background, and a shader that only draws when the
/// terminal has something new (one that animated would keep a still terminal drawing). With neither, nothing is set.
@MainActor   // ghostty_init, one test at a time with programCopiesAreFlagged's
@Test func aThemeReachesGhosttysConfig() throws {
    var a = TerminalAppearance()
    a.opacity = 0.5
    a.shader = "crt"
    let config = a.configText
    // A config needs ghostty_init, though no app.
    try #require(ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("kelp-theme-\(UUID().uuidString).conf")
    try config.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let cfg = ghostty_config_new()
    defer { ghostty_config_free(cfg) }
    ghostty_config_load_file(cfg, file.path)
    ghostty_config_finalize(cfg)
    #expect(ghostty_config_diagnostics_count(cfg) == 0)
    var opacity = 0.0
    #expect(ghostty_config_get(cfg, &opacity, "background-opacity", 18) && opacity == 0.5)
    var animation: UnsafePointer<CChar>?
    #expect(ghostty_config_get(cfg, &animation, "custom-shader-animation", 23))
    #expect(animation.map { String(cString: $0) } == "false")
    let line = try #require(config.split(separator: "\n").first { $0.hasPrefix("custom-shader = ") })
    #expect(FileManager.default.fileExists(atPath: String(line.dropFirst("custom-shader = ".count))))

    a.opacity = 1
    a.shader = "no such shader"
    #expect(!a.configText.contains("background-opacity") && !a.configText.contains("custom-shader"))
}
