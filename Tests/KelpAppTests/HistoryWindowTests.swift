import AppKit
import DesignKit
import Testing

@testable import BuiltinAgents
@testable import KelpApp
@testable import KelpKit

/// Session History's wait and its empty state stand under the list's column titles: the wait's rows were drawn over
/// them. The window is built, never shown.
@MainActor @Test func theHistorysWaitAndEmptyStateStandUnderTheColumnTitles() throws {
    let history = HistoryWindow(app: AppModel(builtins: []))
    history.build()
    let content = try #require(history.window?.contentView)
    content.layoutSubtreeIfNeeded()
    let header = try #require(content.allSubviews(of: NSTableHeaderView.self).first)
    let overlays: [NSView] = content.allSubviews(of: LoadingView.self) + content.allSubviews(of: EmptyStateView.self)
    #expect(overlays.count == 2)
    func frame(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
    #expect(frame(header).height > 0)
    for overlay in overlays { #expect(frame(overlay).maxY <= frame(header).minY) }
}
