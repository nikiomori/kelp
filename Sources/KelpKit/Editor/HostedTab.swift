import AppKit
import Core
import DesignKit
import SwiftUI

/// A tab's SwiftUI content as its view: it fills the pane from the top left, and never resizes the window to its ideal
/// size (which a hosting view would).
@MainActor
final class HostedTab: NSHostingView<AnyView> {
    convenience init(_ content: some View) {
        self.init(rootView: AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)))
    }
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A tab that is SwiftUI content alone, with a fixed title and icon; what it names in `watching` is watched for as long
/// as the tab is open.
@MainActor
package final class HostedTabContent: TabContent {
    package let uri: String
    package let view: NSView
    package let title: String
    package let icon: NSImage?
    private let watched: [Watched]

    package init(
        uri: String, title: String, icon: String, app: AppModel, watching: [(WatchTopic, String)] = [],
        _ content: some View
    ) {
        self.uri = uri
        self.title = title
        self.icon = .symbol(icon)
        watched = watching.map { topic, key in
            let watch = Watched(topic, in: app)
            watch.key = key
            return watch
        }
        view = HostedTab(content)
    }
    package func focus() {}
}
