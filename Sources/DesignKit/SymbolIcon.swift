import SwiftUI

/// A symbol named by data (a panel's, an extension's, a pull request's) in SwiftUI. It uses Kelp's own drawing where
/// Kelp has one, as `NSImage.symbol` does in AppKit, so Settings shows a panel with the same icon as the inspector. It
/// sits in a square of one width, so the words beside a column of symbols start on one line, whatever each symbol's own
/// width.
public struct SymbolIcon: View {
    private let name: String
    private let size: CGFloat

    public init(_ name: String, size: CGFloat = Metrics.iconPoint) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Group {
            // A glyph is drawn 3 pt over the point size it stands beside, because a symbol is taller than its point
            // size too.
            if let glyph = Glyph.image(name, size: size + 3) {
                Image(nsImage: glyph).renderingMode(.template)
            } else {
                Image(systemName: name).font(.symbol(size))
            }
        }
        .frame(width: Metrics.iconMenu)
    }
}
