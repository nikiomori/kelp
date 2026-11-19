import AppKit
import DesignKit
import Testing

/// With Settings › Appearance › Text size, a bar's icon buttons and search toggles grow as its worded buttons do, so
/// one bar's buttons stay one height. A section's count capsule grows with its digits. At normal text each is as it was.
@MainActor @Test func iconButtonsTogglesAndCountsGrowWithTheText() {
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
        #expect(grown.icon == grown.words && grown.toggle == grown.words, "\(size)")
        #expect(grown.icon > normal.icon && grown.count > normal.count, "\(size)")
    }
    TextSize.apply(nil)
    let back = sizes()
    #expect(back.icon == normal.icon && back.count == normal.count && back.icon == back.words)
}
