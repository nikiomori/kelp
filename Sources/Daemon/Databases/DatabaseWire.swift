import Core
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO
import os

/// Shared parts for speaking Postgres and MySQL from kelpd itself, at an address kelpd reaches (the database's own
/// address or a forwarded port), so the Mac needs no psql or mysql. Each call opens one connection and closes it after.
/// Reads run in a read-only transaction, so the server refuses a change (`DatabaseFailure.change`). TLS is used as the
/// database's sslmode says (`tls`).
enum DatabaseWire {
    static let logger: Logger = {
        var logger = Logger(label: "kelp.db")
        logger.logLevel = .critical
        return logger
    }()

    /// TLS settings for the database's sslmode, as libpq reads it. verify-ca checks that the server's certificate comes
    /// from a root the Mac trusts (or ~/.postgresql/root.crt, where psql looks for one), and verify-full checks the
    /// name in it too, so it needs a name rather than an address. Any other mode takes whatever certificate the server
    /// shows, as psql's prefer and require do.
    static func tls(_ db: DatabaseInfo) throws -> TLSConfiguration {
        var config = TLSConfiguration.makeClientConfiguration()
        switch db.ssl {
        case "verify-full":
            guard let host = db.host, !isAddress(host) else {
                throw DatabaseFailure.failed(
                    "sslmode=verify-full checks the server's name in its certificate, and \(db.host ?? db.name) is an "
                        + "address: use the server's name, or verify-ca.")
            }
            config.certificateVerification = .fullVerification
        case "verify-ca": config.certificateVerification = .noHostnameVerification
        default: config.certificateVerification = .none
        }
        let root = NSHomeDirectory() + "/.postgresql/root.crt"
        if db.engine == .postgres, config.certificateVerification != .none, FileManager.default.fileExists(atPath: root)
        {
            config.additionalTrustRoots = [.file(root)]
        }
        return config
    }

    /// Whether the database's sslmode refuses a connection without TLS.
    static func requiresTLS(_ db: DatabaseInfo) -> Bool { ["require", "verify-ca", "verify-full"].contains(db.ssl) }

    static func isAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Says a certificate that failed the check sslmode asked for in those words, rather than as NIOSSL's error.
    /// Returns nil for any other error.
    static func uncertified(_ error: any Error, _ db: DatabaseInfo) -> DatabaseFailure? {
        let said = "\(error)" + ((error as? PSQLError)?.underlying.map { " \($0)" } ?? "")
        let failed = ["CERTIFICATE_VERIFY_FAILED", "failedToValidateHostname", "unableToValidateCertificate"]
        guard failed.contains(where: said.contains) else { return nil }
        return .failed(
            "\(db.name)'s certificate didn't pass the check sslmode=\(db.ssl ?? "verify-ca") asks for: it isn't from a "
                + "root this Mac trusts\(db.ssl == "verify-full" ? ", or isn't for \(db.host ?? "this name")" : "").")
    }

    static var eventLoop: any EventLoop { MultiThreadedEventLoopGroup.singleton.any() }

    /// The failure for a login refused because Kelp has no password. Its message says where to give one.
    static func noPassword(_ db: DatabaseInfo) -> DatabaseFailure {
        .failed("Kelp has no password for \(db.name): Edit… to type one, or import it again.")
    }

    /// Reports a host the network doesn't know (a VPN's or a cluster's internal name) in those words, rather than as
    /// NIO's error. Returns nil for any other error.
    static func unreached(_ error: any Error, _ db: DatabaseInfo) -> DatabaseFailure? {
        let said = "\(error)" + ((error as? PSQLError)?.underlying.map { " \($0)" } ?? "")
        guard said.contains("UnknownHost") || said.contains("nodename nor servname") else { return nil }
        return .failed("Can't find \(db.host ?? db.name) on the network: is a VPN or SSH needed to reach it?")
    }

    /// Runs `body` with a limit on the call's whole time, beyond the server's own time limit. A network lost mid-read
    /// (a VPN dropped, the Mac asleep) never answers, so once `seconds` pass the connection is closed, which ends
    /// whatever waits on it.
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

    /// Returns what `future` gives, or fails once `seconds` have passed and then calls `late`. This is for a step
    /// whose future can't be cancelled or closed (a handshake), which `within` would wait out.
    static func first<T: Sendable>(
        _ future: EventLoopFuture<T>, within seconds: TimeInterval, _ db: DatabaseInfo,
        late: @escaping @Sendable () -> Void
    ) async throws -> T {
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
        /// Resumes the caller with `result`, and returns whether this answer (the timer's or the future's) came first.
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

    /// Closes a connection after its call and only logs a failure, because a connection the server already dropped
    /// has nothing more to say.
    static func close(_ body: () async throws -> Void) async {
        do { try await body() } catch { logger.debug("db close: \(error)") }
    }
}

/// Either the call's answer, or `late` when the call's time ran out first (`DatabaseWire.within`).
private enum WireOutcome<T: Sendable>: Sendable {
    case done(T)
    case late
}
