import AppKit
import DesignKit

/// SF Symbols for Kelp's own pages, which can't type them: each is drawn once into a PNG and given to the page as a
/// CSS mask (`.kelp-sym-xmark`), so it takes the text's colour and size like a letter would.
@MainActor
enum PageSymbols {
    static let names = [
        "xmark", "pencil", "arrow.up", "arrow.uturn.backward", "ellipsis",
        // Edit's Arrange (`CanvasEditMore`)
        "arrow.right", "arrow.down", "align.horizontal.left", "align.horizontal.center", "align.horizontal.right",
        "arrow.left.and.right", "align.vertical.top", "align.vertical.center", "align.vertical.bottom",
        "arrow.up.and.down",
        // the column and the inspector: text alignment, a menu's chevron, done, a draft's grip, keyframe steps
        "text.alignleft", "text.aligncenter", "text.alignright", "chevron.down", "checkmark", "line.3.horizontal",
        "chevron.left", "chevron.right", "diamond.fill",
        // several elements spaced evenly (`CanvasMulti`)
        "distribute.horizontal.center", "distribute.vertical.center",
        // a board's layers: hidden, locked (`CanvasLayers`)
        "eye", "eye.slash", "lock", "lock.open",
        // zoom, what the check found, a mark that is a question
        "minus", "plus", "exclamationmark.triangle", "questionmark"
    ]

    /// Symbol `name` as a span for a button's `innerHTML` (`back.innerHTML = …`), a JS string.
    nonisolated static func span(_ name: String) -> String {
        "'<span class=\"kelp-sym-\(name.replacingOccurrences(of: ".", with: "-"))\" aria-hidden=\"true\"></span>'"
    }

    /// The script that adds the symbols' CSS to the page. Each symbol is also a variable (`--kelp-sym-chevron-down`)
    /// for CSS that draws one itself (a pop-up's `::after`).
    static func script() -> String { css }

    /// Drawn once: the symbols are masks, the same in light and dark.
    private static let css: String = {
        let masks = names.compactMap { name in
            png(name).map { (name.replacingOccurrences(of: ".", with: "-"), data: $0.base64EncodedString()) }
        }
        let vars = masks.map { "--kelp-sym-\($0.0): url(data:image/png;base64,\($0.data));" }.joined(separator: " ")
        let rules = masks.map {
            ".kelp-sym-\($0.0) { -webkit-mask: var(--kelp-sym-\($0.0)) center / contain no-repeat; }"
        }
        .joined(separator: "\n")
        let all = """
            :root { \(vars) }
            [class^="kelp-sym-"], [class*=" kelp-sym-"] { display: inline-block; width: 1em; height: 1em;
              background: currentColor; vertical-align: -0.15em; }
            """
        let text = MarkdownTab.js(all + "\n" + rules)
        return "(function(){ const s = document.createElement('style'); s.textContent = \(text);"
            + " document.head.append(s); })();"
    }()

    /// Symbol `name` drawn black at twice its point size, as PNG.
    private static func png(_ name: String) -> Data? {
        let image = NSImage.symbol(name)
        let side = Metrics.iconPoint * 2
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let k = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * k, height: image.size.height * k)
        image.draw(
            in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
