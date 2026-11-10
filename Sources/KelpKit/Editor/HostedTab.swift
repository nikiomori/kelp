import AppKit
import SwiftUI

/// A tab's SwiftUI content as its view: it fills the pane from the top left, and never resizes the window to its ideal
/// size (which a hosting view would).
@MainActor
package final class HostedTab: NSHostingView<AnyView> {
    package convenience init(_ content: some View) {
        self.init(rootView: AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)))
    }
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    required init?(coder: NSCoder) { fatalError() }
}
