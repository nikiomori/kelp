import Foundation

/// How a design holds up in other languages, without a translation (Framer's locale preview, pseudo-localisation):
/// beside the themes, As Is · +40% · RTL. +40% swaps each letter of the boards' text for an accented one and makes it
/// 40% longer, as German or Finnish would; RTL lays the boards out right to left, as Arabic or Hebrew would. Check runs
/// again in that view, so what it cuts off is found. A mark made in it remembers it (`language`) and tells the agent.
/// Edit puts the boards back as they are first, since it writes what they show.
enum CanvasLanguages {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas, M = window.kelpMarks; if (!K) return;
          if (document.body.matches('.kelp-motion-page, .kelp-dash')) return;
          const accents = { a: 'á', e: 'é', i: 'í', o: 'ó', u: 'ú', c: 'ç', n: 'ñ', s: 'ś', y: 'ý', A: 'Á', E: 'É',
            O: 'Ó', U: 'Ú', а: 'á', е: 'é', о: 'ó', у: 'ý', и: 'ӣ', к: 'ќ', д: 'đ', с: 'ŝ', А: 'Á', Е: 'É', О: 'Ó' };
          const kept = new Map();   // a text node and the words it had
          let now = 'as';
          const longer = t => {
            const words = t.replace(/[\\p{L}]/gu, ch => accents[ch] || ch);
            const pad = ' ' + 'ŕ'.repeat(Math.max(1, Math.round(t.trim().length * 0.4)));
            return t.replace(/\\S[\\s\\S]*\\S|\\S/, m => '[' + words.trim() + pad + ']');
          };
          function texts(doc) {
            const walk = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, { acceptNode: n =>
              /\\p{L}/u.test(n.textContent) && !n.parentElement.closest('style, script')
                ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT });
            const out = []; for (let n = walk.nextNode(); n; n = walk.nextNode()) out.push(n);
            return out;
          }
          function show(view) {
            now = view;
            for (const [n, t] of kept) n.textContent = t;
            kept.clear();
            for (const f of K.frames) {
              const doc = f.contentDocument; if (!doc?.body) continue;
              doc.documentElement.dir = view === 'rtl' ? 'rtl' : '';
              if (view !== 'longer') continue;
              for (const n of texts(doc)) { kept.set(n, n.textContent); n.textContent = longer(n.textContent); }
            }
            for (const b of seg.children) b.classList.toggle('on', b.dataset.view === view);
            window.kelpRecheck?.();
          }
          const seg = K.el('span', 'kelp-seg kelp-langs');
          for (const [view, title] of [['as', L.asIs], ['longer', L.longer], ['rtl', L.rtl]]) {
            const b = K.el('button', view === now ? 'on' : '', title);
            b.dataset.view = view; b.title = L[view + 'Tip'] || '';
            b.onclick = () => show(view);
            seg.append(b);
          }
          document.querySelector('.kelp-themes')?.prepend(seg, K.el('span', 'kelp-sep'));
          // Edit writes what the boards show into their files: it sees them as they are.
          const edit = window.kelpEdit;
          if (edit) window.kelpEdit = on => { if (on && now !== 'as') show('as'); edit(on); };
          if (!M) return;
          const add = M.add.bind(M);
          M.add = m => { if (now !== 'as') m.language = now; add(m); };
          const hooks = K.hooks, what = hooks.what, focus = hooks.focus;
          hooks.what = m => what(m) + (m.language ? ' · ' + (m.language === 'rtl' ? L.rtl : L.longer) : '');
          hooks.focus = m => { if ((m.language || 'as') !== now) show(m.language || 'as'); focus(m); };
        """

    static let style = """
        .kelp-langs { margin-right: 2px; }
        .kelp-themes .kelp-sep { width: 1px; height: 14px; background: var(--k-sep); margin: 0 4px; }
        """
}
