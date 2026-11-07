import Foundation

/// Whether `cond` holds within `timeout` seconds, asked every 50 ms: the one way a test waits for something to happen.
/// It returns false when time runs out, so a test says `#expect(try await waitFor { … })` and a wait that never ends
/// fails there, not at a later check that reads like another bug. In the caller's isolation (a main-actor test reads
/// its views).
public func waitFor(_ timeout: Double = 8, isolation: isolated (any Actor)? = #isolation,
                    _ cond: () async throws -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if try await cond() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return try await cond()
}
