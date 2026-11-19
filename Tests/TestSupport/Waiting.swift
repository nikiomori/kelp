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

/// `waitFor` for a test that mustn't await (the pool it would resume on is what it holds, or a blocking read is what it
/// waits on): asks `cond` every 50 ms on this thread, and records an issue at the caller's line when it runs out.
@discardableResult
public func waitBlocking(
    _ timeout: Double = 8, sourceLocation: SourceLocation = #_sourceLocation, _ cond: () throws -> Bool
) rethrows -> Bool {
    let end = Date().addingTimeInterval(timeout * testSlowness)
    while Date() < end {
        if try cond() { return true }
        usleep(50_000)
    }
    if try cond() { return true }
    Issue.record("waited \(timeout * testSlowness) s and it never held", sourceLocation: sourceLocation)
    return false
}

/// Makes a blocking `read` of `fd` give up after `seconds`, stretched by `testSlowness` as every wait is: an answer
/// that never comes fails the test instead of hanging the run, and one that comes late on a busy runner still counts.
public func readTimeout(_ fd: Int32, _ seconds: Double) {
    let scaled = seconds * testSlowness
    var limit = timeval(tv_sec: Int(scaled), tv_usec: Int32((scaled - scaled.rounded(.down)) * 1_000_000))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
}
