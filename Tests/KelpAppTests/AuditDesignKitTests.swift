import AppKit
import DesignKit
import Testing

/// With Settings › Appearance › Text size, a section's count capsule and a worded button grow with their words, and an
/// icon button and a search toggle keep their 22 pt square, as toolbar symbols do: Pull's and Push's arrows beside them
/// don't grow either. At normal text each is as it was.
@MainActor @Test func countsAndWordsGrowWithTheTextAndIconsKeepTheirSize() {
    defer { TextSize.apply(nil) }
    func sizes() -> (icon: CGFloat, toggle: CGFloat, words: CGFloat, count: CGFloat) {
        let icon = IconButton(.symbol("plus"), tip: "Add") {}
        let count = CountCapsule()
        count.text = "3"
        return (
            icon.fittingSize.height, TextToggle("Aa", tip: "Match Case") {}.fittingSize.height,
            TextButton("Commit").fittingSize.height, count.fittingSize.height
        )
    }
    let normal = sizes()
    for size in ["large", "larger"] {
        TextSize.apply(size)
        let grown = sizes()
        #expect(grown.icon == normal.icon && grown.toggle == normal.toggle, "\(size)")
        #expect(grown.words > normal.words && grown.count > normal.count, "\(size)")
    }
    TextSize.apply(nil)
    let back = sizes()
    #expect(back.words == normal.words && back.count == normal.count)
}
