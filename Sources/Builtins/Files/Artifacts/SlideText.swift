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
        let found = try await web.callAsyncJavaScript(
            Self.takeWords(of: "kelpSlides[i]", box: "slide.getBoundingClientRect()"), arguments: ["i": i],
            contentWorld: Self.world)
        return Self.texts(found)
    }

    /// The blocks of text `takeWords` found.
    static func texts(_ found: Any?) -> [PowerPoint.Text] {
        (found as? [[String: Any]] ?? []).compactMap { t in
            let number = { (key: String) in (t[key] as? NSNumber)?.doubleValue ?? 0 }
            let words = t["words"] as? String ?? "", fill = t["fill"] as? String, cells = t["cells"] as? [[String]]
            guard !words.isEmpty || fill != nil || cells != nil else { return nil }
            return PowerPoint.Text(
                x: number("x"), y: number("y"), w: number("w"), h: number("h"), words: words, size: number("size"),
                bold: t["bold"] as? Bool ?? false, italic: t["italic"] as? Bool ?? false,
                colour: t["colour"] as? String ?? "000000", align: t["align"] as? String ?? "l",
                font: t["font"] as? String ?? "Helvetica Neue", fill: fill, radius: number("radius"), cells: cells)
        }
    }

    /// The script that reads and hides the words of `slide` (a JS expression), placed in `box` (one, as a rect).
    static func takeWords(of slide: String, box: String) -> String {
        "const slide = \(slide), b = \(box), k = 1920 / b.width;\n" + takeWords
    }

    private static let takeWords = """
        const shown = e => { const s = getComputedStyle(e); return s.display !== 'none' && s.visibility !== 'hidden'; };
        const block = e => !getComputedStyle(e).display.startsWith('inline');
        const words = e => (e.innerText || '').trim();
        const blocks = [...slide.querySelectorAll('*')].filter(e => shown(e) && words(e) && !e.closest('table')
          && (block(e) || e.parentElement === slide)
          && ![...e.querySelectorAll('*')].some(c => block(c) && words(c)));
        const hex = c => '#' + (c.match(/[0-9.]+/g) || [0, 0, 0]).slice(0, 3)
          .map(v => Math.round(+v).toString(16).padStart(2, '0')).join('');
        // What it was before Kelp hid parts of it, put back by `showWords`; kept once.
        const keep = e => { if (!('kelpWords' in e.dataset)) e.dataset.kelpWords = e.getAttribute('style') || ''; };
        const at = r => ({ x: (r.left - b.left) / b.width, y: (r.top - b.top) / b.height, w: r.width / b.width,
          h: r.height / b.height });
        // A box filled with one colour (a card, a button, a band) is a shape, under the words.
        const solid = c => { const v = (c.match(/[0-9.]+/g) || []).map(Number);
          return v.length >= 3 && (v.length < 4 || v[3] > 0.9); };
        const shapes = [...slide.querySelectorAll('*')].filter(e => {
          if (!shown(e) || e.closest('table')) return false;
          const st = getComputedStyle(e), r = e.getBoundingClientRect();
          return solid(st.backgroundColor) && st.backgroundImage === 'none' && r.width > 4 && r.height > 4
            && r.width * r.height < b.width * b.height * 0.6;
        }).map(e => {
          const r = e.getBoundingClientRect(), st = getComputedStyle(e);   // live: read before hiding
          const out = { ...at(r), words: '', size: 0, fill: hex(st.backgroundColor).slice(1).toUpperCase(),
            radius: (parseFloat(st.borderTopLeftRadius) || 0) / Math.min(r.width, r.height) };
          keep(e); e.style.setProperty('background-color', 'transparent', 'important');
          return out;
        });
        // A table is a table, its first row's ground its header's.
        const tables = [...slide.querySelectorAll('table')].filter(shown).map(t => {
          const r = t.getBoundingClientRect(), first = t.querySelector('td, th'), st = getComputedStyle(first || t);
          const head = t.querySelector('tr') && getComputedStyle(t.querySelector('tr').firstElementChild || t);
          const out = { ...at(r), words: '', size: parseFloat(st.fontSize) * k * 0.5,
            colour: hex(st.color).slice(1).toUpperCase(),
            fill: head && solid(head.backgroundColor) ? hex(head.backgroundColor).slice(1).toUpperCase() : null,
            cells: [...t.querySelectorAll('tr')].map(tr => [...tr.children].map(c => (c.innerText || '').trim())) };
          keep(t); t.style.setProperty('visibility', 'hidden', 'important');
          return out;
        });
        return shapes.concat(tables, blocks.map(e => {
          const r = e.getBoundingClientRect(), st = getComputedStyle(e);
          // The Mac's own font has no name PowerPoint knows; a list item keeps its bullet, hidden with its words.
          const family = st.fontFamily.split(',')[0].trim().replace(/^['"]|['"]$/g, '');
          const bullet = e.tagName === 'LI' && st.listStyleType !== 'none' ? '• ' : '';
          const out = { ...at(r), words: bullet + words(e), size: parseFloat(st.fontSize) * k * 0.5,
            bold: +st.fontWeight >= 600, italic: st.fontStyle === 'italic',
            colour: hex(st.color).slice(1).toUpperCase(),
            align: { center: 'ctr', right: 'r', end: 'r' }[st.textAlign] || 'l',
            font: /^(-apple-system|system-ui|BlinkMacSystemFont)$/.test(family) ? 'Helvetica Neue' : family };
          keep(e);
          e.style.setProperty('color', 'transparent', 'important');
          e.style.setProperty('-webkit-text-fill-color', 'transparent', 'important');
          e.style.setProperty('text-shadow', 'none', 'important');
          return out;
        }));
        """

    static let showWords = """
        for (const e of document.querySelectorAll('[data-kelp-words]')) {
          const was = e.dataset.kelpWords; delete e.dataset.kelpWords;
          if (was) e.setAttribute('style', was); else e.removeAttribute('style');
        }
        """
}
