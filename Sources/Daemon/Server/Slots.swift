import Core
import Foundation
import os

/// Lets at most `limit` holders run at once. The rest wait first come, first served, suspended, holding no thread.
/// Limit: a waiter whose task is cancelled still takes its turn; nothing here cancels (a client's deadline is its own).
final class Slots: Sendable {
    let limit: Int
    private struct State {
        var held = 0, closed = false, refused = 0
        var waiting: [CheckedContinuation<Bool, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// A separate cap for quick work (a thread each). Quick work never waits behind slow work, only behind this much
    /// quick work at once, so a client looping on `kelp hook` can't make thousands of threads.
    private let quickSlots: Slots?
    /// A separate cap for `runNow`, so its work never waits behind slow work and a client looping on attach can't make
    /// a thread per call.
    private let nowSlots: Slots?
    init(_ limit: Int, quick: Int? = 64) {
        self.limit = limit
        quickSlots = quick.map { Slots($0, quick: nil) }
        nowSlots = quick.map { Slots($0 / 2, quick: nil) }
    }

    /// Waits for a slot. Returns false once closed (`close`), because no slot is given from then on.
    func acquire() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let now = state.withLock { current -> Bool? in
                if current.closed {
                    current.refused += 1
                    return false
                }
                guard current.held < limit else {
                    current.waiting.append(continuation)
                    return nil
                }
                current.held += 1
                return true
            }
            if let now { continuation.resume(returning: now) }
        }
    }

    /// How many requests were refused after closing, counting quick work and `runNow` too, so a test can wait for a
    /// refusal instead of a fixed time.
    var refusals: Int {
        state.withLock { $0.refused } + (quickSlots?.refusals ?? 0) + (nowSlots?.refusals ?? 0)
    }

    /// Releases a slot. It passes straight to the longest waiter, if there is one.
    func release() {
        let next = state.withLock { current -> CheckedContinuation<Bool, Never>? in
            guard !current.waiting.isEmpty else {
                current.held -= 1
                return nil
            }
            return current.waiting.removeFirst()
        }
        next?.resume(returning: true)
    }

    /// Closes the slots because an update is on its way. Work that has a slot finishes (`waitIdle`), no new work
    /// starts, and what waits is refused.
    func close() {
        let refused = state.withLock { current in
            defer { current.waiting = [] }
            current.closed = true
            current.refused += current.waiting.count
            return current.waiting
        }
        refused.forEach { $0.resume(returning: false) }
        quickSlots?.close()
        nowSlots?.close()
    }

    /// Runs `work` on a thread of its own, with programs allowed. What the user is waiting to see (a paused agent's tab
    /// waking) then doesn't queue behind slow git or ssh, only behind as much work of its own kind as its cap allows.
    func runNow<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        if let nowSlots { return try await nowSlots.run(work) }
        return try await Self.onThread { Result(catching: work) }
    }

    /// Waits until no slot is held (what's running has finished), for at most `seconds`. It checks every 50 ms, which
    /// an update (the one caller) can afford. Work that keeps coming keeps it waiting to the end, as it should.
    func waitIdle(seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while busy, Date() < end { usleep(50_000) }
    }
    /// Whether a slot is held here, by a wake (`runNow`, which starts programs too) or by a quick handler (a report,
    /// whose reply would be lost to an update's exec).
    private var busy: Bool { state.withLock { $0.held > 0 } || nowSlots?.busy == true || quickSlots?.busy == true }

    /// Runs `work` on a thread of its own once it has a slot (`Daemon.offload`). `quick` work runs at once, with no
    /// slot and no program.
    func run<T: Sendable>(quick: Bool = false, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let slots = quick ? quickSlots : self, asker = Sessions.asker   // a new thread doesn't inherit `asker`
        if let slots, await !slots.acquire() { throw RPCError.updating }
        return try await Self.onThread {
            defer { slots?.release() }
            return Sessions.$asker.withValue(asker) {
                quick ? Result { try Subprocess.quickOnly(work) } : Result(catching: work)
            }
        }
    }

    /// Runs work that blocks briefly on a thread of its own, where no `Slots` is at hand (looking up a host name with
    /// `getaddrinfo`).
    static func elsewhere<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await onThread { Result(catching: work) }
    }

    /// Runs `body` on a thread of its own and hands its result back under a lock, so what it made (a woken session) is
    /// seen whole by whoever reads it after. The continuation alone would order it too, but the Thread Sanitizer can't
    /// see that
    /// (Swift's concurrency library isn't built for it) and reported the session's fields as a race.
    private static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> Result<T, Error>) async throws -> T {
        let handed = OSAllocatedUnfairLock<Result<T, Error>?>(initialState: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread {
                let result = body()
                handed.withLock { $0 = result }
                continuation.resume()
            }
        }
        guard let result = handed.withLock({ $0 }) else { throw RPCError.internalError("no result") }
        return try result.get()
    }
}
