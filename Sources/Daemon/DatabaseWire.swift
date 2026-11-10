import Core
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO
import os

/// Postgres and MySQL spoken by kelpd itself, at an address it reaches (the database's own, or a forwarded port): no
/// psql or mysql on the Mac. One connection a call, closed after it. Reads run in a read-only transaction, so the
/// server refuses a change (`DatabaseFailure.change`); TLS is used when the server offers it, its certificate not
/// checked (as psql's default `sslmode=prefer` does).
enum DatabaseWire {
    static let logger: Logger = {
        var logger = Logger(label: "kelp.db")
        logger.logLevel = .critical
        return logger
    }()

    /// TLS that takes what the server shows: the connection is to a server the user named.
    static let tls: TLSConfiguration = {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = .none
        return config
    }()

    static var eventLoop: any EventLoop { MultiThreadedEventLoopGroup.singleton.any() }

    /// A login refused for want of a password: where to give one.
    static func noPassword(_ db: DatabaseInfo) -> DatabaseFailure {
        .failed("Kelp has no password for \(db.name): Edit… to type one, or import it again.")
    }

    /// A host the network doesn't know (a VPN's, a cluster's inside name): said as such, not as NIO's error.
    static func unreached(_ error: any Error, _ db: DatabaseInfo) -> DatabaseFailure? {
        let said = "\(error)" + ((error as? PSQLError)?.underlying.map { " \($0)" } ?? "")
        guard said.contains("UnknownHost") || said.contains("nodename nor servname") else { return nil }
        return .failed("Can't find \(db.host ?? db.name) on the network: is a VPN or SSH needed to reach it?")
    }

    /// The call's whole time, past what the server's own limit stops: a network gone mid-read (a VPN dropped, the Mac
    /// asleep) answers nothing, so past it the connection is closed, which ends what waits on it.
    static func within<T: Sendable>(
        _ seconds: TimeInterval, _ db: DatabaseInfo, close: @escaping @Sendable () async -> Void,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: WireOutcome<T>.self) { group in
            group.addTask { .done(try await body()) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return .late
            }
            defer { group.cancelAll() }
            if case .done(let result) = try await group.next() { return result }
            await close()
            throw DatabaseFailure.failed("No answer from \(db.name) in \(Int(seconds)) s.")
        }
    }

    /// What `future` gives, or a failure once `seconds` have passed (then `late`): for a step whose future can't be
    /// cancelled or closed (a handshake), which `within` would wait out.
    static func first<T: Sendable>(
        _ future: EventLoopFuture<T>, within seconds: TimeInterval, _ db: DatabaseInfo,
        late: @escaping @Sendable () -> Void
    ) async throws -> T {
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
        /// Whether it was the first to answer.
        @Sendable func give(_ result: Result<T, any Error>) -> Bool {
            let continuation = waiting.withLock { held in
                defer { held = nil }
                return held
            }
            continuation?.resume(with: result)
            return continuation != nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.withLock { $0 = continuation }
            let timer = future.eventLoop.scheduleTask(in: .milliseconds(Int64(seconds * 1000))) {
                let said = "No answer from \(db.name) in \(Int(seconds.rounded(.up))) s."
                if give(.failure(DatabaseFailure.failed(said))) { late() }
            }
            future.whenComplete { result in
                timer.cancel()
                _ = give(result)
            }
        }
    }

    /// A connection closed after its call: one the server dropped already has nothing more to say.
    static func close(_ body: () async throws -> Void) async {
        do { try await body() } catch { logger.debug("db close: \(error)") }
    }
}

/// The call's answer, or its time ran out first (`DatabaseWire.within`).
private enum WireOutcome<T: Sendable>: Sendable {
    case done(T)
    case late
}
