import SwiftUI

/// The ⓘ beside a row's title. It shows the row's whole help on hover, or in a popover on a click, so the row stays one
/// line: a paragraph under a control is what this stands in for, in Settings' rows and in a built-in's own screen.
public struct HelpMark: View {
    private let text: String
    @State private var shown = false
    public init(text: String) { self.text = text }
    public var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle").font(.symbol()).foregroundStyle(.secondary)
        }
        .buttonStyle(PointerButtonStyle(flush: true)).padding(.vertical, -3)   // so the row keeps its height
        .help(text)
        .accessibilityLabel(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).fixedSize(horizontal: false, vertical: true).frame(width: 280, alignment: .leading).padding(
                Metrics.inset)
        }
    }
}
