import Foundation
import Testing

/// The executable `name` (kelp, kelpd) built beside the running test bundle, wherever this build's products went
/// (`.build`, a `--scratch-path`, CI's sanitizer build): found from the bundle's own place (TestSupportC), never from
/// the source tree, where a `.build/debug/kelp` left by an older build would pass for this one.
public func builtProduct(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
    let kelp = try #require(
        ProcessInfo.processInfo.environment["KELP_TRAMPOLINE"], "no kelp beside the test bundle",
        sourceLocation: sourceLocation)
    let path = URL(fileURLWithPath: kelp).deletingLastPathComponent().appendingPathComponent(name).path
    try #require(
        FileManager.default.isExecutableFile(atPath: path), "\(path) isn't built", sourceLocation: sourceLocation)
    return path
}
