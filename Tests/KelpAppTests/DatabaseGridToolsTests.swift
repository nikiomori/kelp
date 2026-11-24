import AppKit
import Core
import DesignKit
import TestSupport
import Testing

@testable import BuiltinDatabases
@testable import KelpKit

/// A statement that runs past a second shows Stop where Run is, with ⌘.; once it ends, Run is back.
@MainActor @Test func stopTakesRunsPlaceWhileAStatementRuns() async throws {
    let (tab, window) = editableTab([])
    defer { withExtendedLifetime(window) {} }
    #expect(try await waitFor { !tab.failureBar.isHidden })   // the tab's own first read is over (no kelpd here)
    tab.mode = .query
    tab.arrange()
    tab.running = "r1"
    tab.startReading()
    #expect(tab.stopButton.isHidden && !tab.run.isHidden)   // a quick statement changes nothing
    #expect(try await waitFor(5) { !tab.stopButton.isHidden })
    #expect(tab.run.isHidden && tab.stopButton.keyEquivalent == ".")
    tab.arrange()
    #expect(tab.run.isHidden)
    tab.running = nil
    tab.readingEnded()
    #expect(tab.stopButton.isHidden && !tab.run.isHidden)
}
