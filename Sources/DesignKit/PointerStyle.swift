import SwiftUI

/// SwiftUI's side of `PointerButton`, for settings and extension panels: under the pointer a grey fill fades in, held it
/// darkens and the button dips, as Kelp's AppKit controls do. Reduce Motion: the fills change, nothing moves.
public struct PointerButtonStyle: ButtonStyle {
    private let radius: CGFloat
    public init(radius: CGFloat = Metrics.radiusSM) { self.radius = radius }
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View { Pointed(configuration: configuration, radius: radius) }

    private struct Pointed: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 4)
                .frame(minHeight: Metrics.iconButton)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: configuration.isPressed ? .fillSelected : hovering ? .fillHover : .clear)))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.94 : 1)
                .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
                .animation(Motion.reduced ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A card that is a choice (a theme): under the pointer its edge brightens, pressed it dips a little.
public struct PointerCardStyle: ButtonStyle {
    private let radius: CGFloat
    public init(radius: CGFloat = Metrics.radiusMD) { self.radius = radius }
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View { Card(configuration: configuration, radius: radius) }

    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0), lineWidth: 1))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.97 : 1)
                .animation(Motion.reduced ? nil : .easeOut(duration: Motion.fast), value: hovering)
                .animation(Motion.reduced ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
