import SwiftUI

/// Settings' state mark: a filled grey dot when the thing is there (connected, running, installed), a ring when it
/// isn't, and red only when it broke. Words always stand beside it, so VoiceOver hears those and not the dot. It grows
/// with Text size, as the words beside it do.
public struct StateDot: View {
    public enum State: Sendable { case on, off, broken }
    private let state: State
    public init(_ state: State) { self.state = state }
    public init(on: Bool) { state = on ? .on : .off }

    public var body: some View {
        let size = TextSize.of(Metrics.gapWide)
        let colour = state == .broken ? Color.textRed : .secondary
        Circle().strokeBorder(colour, lineWidth: 1.5)
            .background(Circle().fill(state == .off ? .clear : colour))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
