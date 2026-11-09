import Foundation
import Testing

@testable import KelpGuest

/// The command line and the app in the machine, over their socket: a request is answered, an unknown one fails, the
/// session it names isn't taken for the command, and one with no app running says so. `status` only: `ui` and
/// `press` ask for Accessibility, a dialog on the screen.
@MainActor @Test func theCommandLineAsksTheRunningApp() async throws {
    let path = NSTemporaryDirectory() + "kg-\(UUID().uuidString.prefix(6)).sock"
    defer { unlink(path) }
    func ask(_ argv: [String]) async -> Int32 { await Task.detached { Client.ask(argv, socket: path) }.value }
    #expect(await ask(["status"]) == 3, "no app running")
    let server = Server(socket: path)
    server.start()
    #expect(await ask(["status"]) == 0)
    #expect(await ask(["--session", "s-1", "status"]) == 0, "its session isn't the command")
    #expect(await ask(["frobnicate"]) == 1)
    #expect(await ask([]) == 1)
}
