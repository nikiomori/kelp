import Foundation
import Testing

/// How much slower time goes in this run: KELP_TEST_SLOW (CI's Thread Sanitizer job says 4), else 1. Every wait is
/// that much longer; what's waited for is the same.
public let testSlowness = ProcessInfo.processInfo.environment["KELP_TEST_SLOW"].flatMap(Double.init) ?? 1

/// Whether `cond` holds within `timeout` seconds, asked every 50 ms: the one way a test waits for something to happen.
/// A wait that runs out is an issue recorded where it waited (the caller's line), not at a later check that reads like
/// another bug; it still returns false, so a test can add what it saw (`#expect(arrived, "\(screen)")`). In the
/// caller's isolation (a main-actor test reads its views).
@discardableResult
public func waitFor(
    _ timeout: Double = 8, isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ cond: () async throws -> Bool
) async throws -> Bool {
    let end = Date().addingTimeInterval(timeout * testSlowness)
    while Date() < end {
        if try await cond() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    if try await cond() { return true }
    Issue.record("waited \(timeout * testSlowness) s and it never held", sourceLocation: sourceLocation)
    return false
}
