import SwiftUI

/// SwiftUI's side of `PointerButton`, for settings and extension panels. Under the pointer a grey fill fades in, and
/// when held it darkens at once and the button dips by `Motion.pressDip`, as Kelp's AppKit controls do. Under Reduce
/// Motion the fills change and nothing moves. With `flush`, the fill reaches past the label, and its neighbours stand
/// where they would without it (a glyph in a line of text).
public struct PointerButtonStyle: ButtonStyle {
    private let flush: Bool
    public init(flush: Bool = false) { self.flush = flush }
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        Pointed(configuration: configuration).padding(.horizontal, flush ? -Self.padding : 0)
    }
    fileprivate static let padding: CGFloat = 4

    private struct Pointed: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @State private var size = CGSize.zero
        var body: some View {
            configuration.label
                .padding(.horizontal, PointerButtonStyle.padding)
                .frame(minHeight: Metrics.iconButton)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                        .fill(Color(nsColor: configuration.isPressed ? .fillSelected : hovering ? .fillHover : .clear))
                )
                .contentShape(Rectangle())
                .animation(
                    configuration.isPressed || Motion.reduced ? nil : .easeOut(duration: Motion.fast),
                    value: configuration.isPressed
                )
                .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
                .scaleEffect(configuration.isPressed && !Motion.reduced ? Motion.pressDip(size) : 1)
                .animation(Motion.reduced ? nil : .pressSpring, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: {
                    size = $0
                }
        }
    }
}

/// A card that is a choice (a theme). When pressed it dips a little, and under the pointer it tells its label, whose
/// tile brightens its own edge (`cardEdge`). A ring of the style's own went round the caption too, and with the tile's
/// it made two lines.
public struct PointerCardStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View { Card(configuration: configuration) }

    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @State private var size = CGSize.zero
        var body: some View {
            configuration.label
                .environment(\.cardHovering, hovering)
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed && !Motion.reduced ? Motion.pressDip(size) : 1)
                .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
                .animation(Motion.reduced ? nil : .pressSpring, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: {
                    size = $0
                }
        }
    }
}

extension EnvironmentValues {
    /// Whether the pointer is over the `PointerCardStyle` button this view is in.
    @Entry var cardHovering = false
}

extension View {
    /// A choice tile's one edge: the accent when it's the one picked, brighter under the pointer, and a hairline
    /// otherwise.
    public func cardEdge(selected: Bool) -> some View {
        modifier(CardEdge(selected: selected))
    }
}

private struct CardEdge: ViewModifier {
    let selected: Bool
    @Environment(\.cardHovering) private var hovering
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .strokeBorder(
                    selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.35 : 0.15),
                    lineWidth: selected ? 2 : 1))
    }
}

extension View {
    /// Makes a borderless menu (⋯, +) answer the pointer as a `PointerButtonStyle` button beside it does: under the
    /// pointer a grey fill fades in. Its press is the menu opening, which is the system's.
    public func pointerMenu() -> some View { modifier(PointerMenu()) }
}

private struct PointerMenu: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PointerButtonStyle.padding)
            .frame(minHeight: Metrics.iconButton)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .fill(Color(nsColor: hovering ? .fillHover : .clear))
            )
            .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
            .onHover { hovering = $0 }
            // The fill reaches past the glyph, and its neighbours stay where they were.
            .padding(.horizontal, -PointerButtonStyle.padding)
    }
}

extension Animation {
    /// A press dipping and coming back, in SwiftUI (AppKit's is `pressBounce`).
    fileprivate static var pressSpring: Animation { .spring(response: 0.25, dampingFraction: 0.6) }
}
