import SwiftUI

/// `Bar.content` in SwiftUI: a tab's toolbar, 32 pt (with the text size), its controls small, a little room between them,
/// a flexible space where the content puts a `Spacer`. The line under it is the tab's (`Divider()`).
public struct ContentBar<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: Metrics.gapWide) { content }
            .controlSize(.small)
            .buttonStyle(BarButtonStyle())
            .padding(.horizontal, Metrics.inset)
            .frame(height: TextSize.of(Metrics.contentBar))
    }
}

/// `TextButton` for SwiftUI: a button named in words in a tab's bar is the quiet grey plate, darker under the pointer.
/// `ContentBar` gives it to every button it holds.
public struct BarButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }

    private struct Plate: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let fill: NSColor = configuration.isPressed ? .fillSelected : hovering && enabled ? .fillHover : .fillRest
            configuration.label
                .font(.ui(TextSize.row))
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, Metrics.gap)
                .frame(height: TextSize.of(Metrics.iconButton))
                .background(
                    Color(nsColor: fill), in: RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Motion.duration(Motion.fast)), value: hovering)
        }
    }
}
