import AppKit
import Core
import DesignKit
import KelpKit

/// The words of a slide for an editable PowerPoint (`PowerPoint.Text`): each block of text with no block of text inside
/// it, where it is on the slide and how it looks; then hidden, so the slide's picture is taken without them.
extension MarkdownTab {
    /// How the slides become a PowerPoint, chosen under its save panel and kept for the next one: with text that can
    /// be changed (on), or as pictures.
    static var editablePowerPoint: Bool {
        get { UserDefaults.standard.object(forKey: "artifacts.pptxEditable") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "artifacts.pptxEditable") }
    }

    /// The choice under the PowerPoint's save panel: its words as text boxes over each slide's picture, or the slides
    /// as pictures, exactly as here.
    static func powerPointChoice() -> NSPopUpButton {
        let choice = PointerPopUpButton()
        choice.addItems(withTitles: [String(localized: "Text Can Be Changed"), String(localized: "As Pictures")])
        choice.selectItem(at: editablePowerPoint ? 0 : 1)
        choice.sizeToFit()
        return choice
    }

    /// Slide `i`'s blocks of text, hidden after they are read (`showWords` puts them back).
    func slideTexts(_ i: Int) async throws -> [PowerPoint.Text] {
        let found = try await web.callAsyncJavaScript(Self.takeWords, arguments: ["i": i], contentWorld: Self.world)
        return (found as? [[String: Any]] ?? []).compactMap { t in
            let number = { (key: String) in (t[key] as? NSNumber)?.doubleValue ?? 0 }
            guard let words = t["words"] as? String, !words.isEmpty else { return nil }
            return PowerPoint.Text(
                x: number("x"), y: number("y"), w: number("w"), h: number("h"), words: words, size: number("size"),
                bold: t["bold"] as? Bool ?? false, italic: t["italic"] as? Bool ?? false,
                colour: t["colour"] as? String ?? "000000", align: t["align"] as? String ?? "l",
                font: t["font"] as? String ?? "Helvetica Neue")
        }
    }

    static let takeWords = """
        const slide = kelpSlides[i], b = slide.getBoundingClientRect(), k = 1920 / b.width;
        const shown = e => { const s = getComputedStyle(e); return s.display !== 'none' && s.visibility !== 'hidden'; };
        const block = e => !getComputedStyle(e).display.startsWith('inline');
        const words = e => (e.innerText || '').trim();
        const blocks = [...slide.querySelectorAll('*')].filter(e => shown(e) && words(e)
          && (block(e) || e.parentElement === slide)
          && ![...e.querySelectorAll('*')].some(c => block(c) && words(c)));
        const hex = c => '#' + (c.match(/[0-9.]+/g) || [0, 0, 0]).slice(0, 3)
          .map(v => Math.round(+v).toString(16).padStart(2, '0')).join('');
        return blocks.map(e => {
          const r = e.getBoundingClientRect(), st = getComputedStyle(e);
          // The Mac's own font has no name PowerPoint knows; a list item keeps its bullet, hidden with its words.
          const family = st.fontFamily.split(',')[0].trim().replace(/^['"]|['"]$/g, '');
          const bullet = e.tagName === 'LI' && st.listStyleType !== 'none' ? '• ' : '';
          const out = { x: (r.left - b.left) / b.width, y: (r.top - b.top) / b.height, w: r.width / b.width,
            h: r.height / b.height, words: bullet + words(e), size: parseFloat(st.fontSize) * k * 0.5,
            bold: +st.fontWeight >= 600, italic: st.fontStyle === 'italic',
            colour: hex(st.color).slice(1).toUpperCase(),
            align: { center: 'ctr', right: 'r', end: 'r' }[st.textAlign] || 'l',
            font: /^(-apple-system|system-ui|BlinkMacSystemFont)$/.test(family) ? 'Helvetica Neue' : family };
          e.dataset.kelpWords = e.getAttribute('style') || '';
          e.style.setProperty('color', 'transparent', 'important');
          e.style.setProperty('-webkit-text-fill-color', 'transparent', 'important');
          e.style.setProperty('text-shadow', 'none', 'important');
          return out;
        });
        """

    static let showWords = """
        for (const e of document.querySelectorAll('[data-kelp-words]')) {
          const was = e.dataset.kelpWords; delete e.dataset.kelpWords;
          if (was) e.setAttribute('style', was); else e.removeAttribute('style');
        }
        """
}
