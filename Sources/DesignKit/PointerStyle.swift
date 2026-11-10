import SwiftUI

/// SwiftUI's side of `PointerButton`, for settings and extension panels: under the pointer a grey fill fades in, held it
/// darkens at once and the button dips by `Motion.pressDip`, as Kelp's AppKit controls do. Reduce Motion: the fills change,
/// nothing moves.
public struct PointerButtonStyle: ButtonStyle {
    private let radius: CGFloat
    public init(radius: CGFloat = Metrics.radiusSM) { self.radius = radius }
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        Pointed(configuration: configuration, radius: radius)
    }

    private struct Pointed: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @State private var hovering = false
        @State private var size = CGSize.zero
        var body: some View {
            configuration.label
                .padding(.horizontal, 4)
                .frame(minHeight: Metrics.iconButton)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
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

/// A card that is a choice (a theme): pressed it dips a little; under the pointer it tells its label, whose tile brightens
/// its own edge (`cardEdge`). A ring of the style's own went round the caption too, and with the tile's it was two lines.
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
    /// The pointer is over the `PointerCardStyle` button this is in.
    @Entry var cardHovering = false
}

extension View {
    /// A choice tile's one edge: the accent when it's the one picked, brighter under the pointer, a hairline otherwise.
    public func cardEdge(selected: Bool, radius: CGFloat = Metrics.radiusMD) -> some View {
        modifier(CardEdge(selected: selected, radius: radius))
    }
}

private struct CardEdge: ViewModifier {
    let selected: Bool, radius: CGFloat
    @Environment(\.cardHovering) private var hovering
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.35 : 0.15),
                    lineWidth: selected ? 2 : 1))
    }
}

extension View {
    /// A borderless menu (⋯, +) answers the pointer as a `PointerButtonStyle` button beside it does: under it a grey
    /// fill fades in. Its press is the menu opening, which is the system's.
    public func pointerMenu() -> some View { modifier(PointerMenu()) }
}

private struct PointerMenu: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .frame(minHeight: Metrics.iconButton)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .fill(Color(nsColor: hovering ? .fillHover : .clear))
            )
            .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
            .onHover { hovering = $0 }
            .padding(.horizontal, -4)   // the fill reaches past the glyph; its neighbours stay where they were
    }
}

extension Animation {
    /// A press dipping and coming back, in SwiftUI (AppKit's is `pressBounce`).
    fileprivate static var pressSpring: Animation { .spring(response: 0.25, dampingFraction: 0.6) }
}
