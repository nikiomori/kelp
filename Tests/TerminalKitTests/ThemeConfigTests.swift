import Foundation
import Testing
@testable import TerminalKit

@Test func aThemeReachesGhosttysConfig() throws {
    var a = TerminalAppearance()
    a.opacity = 0.5; a.shader = "crt"
    let config = a.configText
    #expect(config.contains("background-opacity = 0.5"))
    #expect(config.contains("custom-shader-animation = false"))   // a shader must not keep a still terminal drawing
    let line = try #require(config.split(separator: "\n").first { $0.hasPrefix("custom-shader = ") })
    #expect(FileManager.default.fileExists(atPath: String(line.dropFirst("custom-shader = ".count))))

    a.opacity = 1; a.shader = "no such shader"
    #expect(!a.configText.contains("background-opacity") && !a.configText.contains("custom-shader"))
}
