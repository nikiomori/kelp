import SwiftUI

/// `Bar.content` in SwiftUI: a tab's toolbar, 32 pt (with the text size), its controls small, a little room between them,
/// a flexible space where the content puts a `Spacer`. The line under it is the tab's (`Divider()`).
public struct ContentBar<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: Metrics.gapWide) { content }
            .controlSize(.small)
            .padding(.horizontal, Metrics.inset)
            .frame(height: TextSize.of(Metrics.contentBar))
    }
}
