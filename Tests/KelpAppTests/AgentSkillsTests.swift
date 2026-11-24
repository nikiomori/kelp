import Foundation
import Testing

@testable import KelpKit

@Test func skillDescriptionIsQuotedYAML() throws {
    let description = "Use when you run tests in Kelp, the IDE: a build, \"quotes\" and a \\ too"
    let front = AgentSkills.frontMatter("kelp-x", description)
    let line = try #require(front.split(separator: "\n").first { $0.hasPrefix("description: ") })
    let value = line.dropFirst("description: ".count)
    #expect(value.hasPrefix("\""))
    #expect(try JSONDecoder().decode(String.self, from: Data(value.utf8)) == description)
}
