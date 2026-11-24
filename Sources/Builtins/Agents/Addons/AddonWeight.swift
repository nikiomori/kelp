import AppKit
import DesignKit
import SwiftUI

/// The summary over the list. It shows what a chat starts with before the first word ("38.4k tokens before the first
/// word") as a bar and a legend of the parts, biggest first. While the weights aren't known, it shows just the counts.
/// In Kelp colour means state, so the parts are shades of the text colour, with the biggest in the accent. `when` is
/// when the chat read it all ("loaded 14:20"), shown beside the headline.
struct AddonWeight: View {
    let headline: String
    let shares: [AddonGroups.Share]
    var when: String?

    private static let shades: [NSColor] = [.emphasis, .secondaryLabelColor, .tertiaryLabelColor, .quaternaryLabelColor]

    private func top(_ when: String?) -> some View {
        HStack(spacing: Metrics.gap) {
            Text(headline).foregroundStyle(shares.isEmpty ? .secondary : .primary).lineLimit(1)
            Spacer(minLength: 0)
            if let when { Text(when).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            // In a narrow inspector `when` goes first, so the headline is never cut while it keeps its room.
            ViewThatFits(in: .horizontal) {
                top(when)
                top(nil)
            }
            .font(.ui(TextSize.caption))
            if !shares.isEmpty {
                let total = Double(shares.reduce(0) { $0 + $1.tokens })
                PartsBar(
                    shares.enumerated().map {
                        PartsBar.Part(id: "\($0.offset)", value: Double($0.element.tokens), color: color($0.offset))
                    },
                    total: total)
                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading, spacing: Metrics.lineGap
                ) {
                    ForEach(Array(shares.enumerated()), id: \.offset) { index, share in legend(share, color(index)) }
                }
            }
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.gap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ index: Int) -> Color { Color(nsColor: Self.shades[min(index, Self.shades.count - 1)]) }

    private func legend(_ share: AddonGroups.Share, _ color: Color) -> some View {
        HStack(spacing: Metrics.gap) {
            PartsBar.Swatch(color)
            Text(share.part.title).lineLimit(1)
            Text(shortTokens(share.tokens)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.ui(TextSize.caption))
    }
}
