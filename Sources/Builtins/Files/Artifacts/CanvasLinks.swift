import Foundation

/// A design as a prototype (Google Stitch): a control links to a board (`BoardLinks`: `href="#board:<name>"` on an
/// `<a>`, `data-link` on anything else). While presenting, a click on one shows the board it goes to. In Edit, a
/// button or a link has Goes To, a menu of the boards (`linkMenu`, answered by `kelpLinkTo`). Once a design has a link,
/// Check also lists its dead ends, the controls that go nowhere, each with Link… and To the Agent (a mark on it
/// asking for the screen after it).
enum CanvasLinks {
    /// A dead end as Check says it: the board, and the control's data-id when it has one.
    static let deadEnd = #"^(.+?)(?: \(dark\))?: «.*» in \[data-id=([^\]]+)\] goes nowhere"#

    static func source(labels: [String: String]) -> String {
        "(function (L, DEAD) {\n" + body + "\n})(\(MarkdownTab.js(labels)), \(MarkdownTab.js(deadEnd)));"
    }

    private static let body = """
          const K = window.kelpCanvas, props = window.kelpProps; if (!K) return;
          if (document.body.matches('.kelp-motion-page, .kelp-dash')) return;
          const files = [...new Set(K.frames.map(f => f.dataset.board))];
          const base = file => file.split('/').pop().replace(/[.][^.]*$/, '');
          const titleOf = file => (K.light(file)?.closest('.frame')?.querySelector('.name')?.firstChild?.textContent
            || base(file)).split(' · ')[0];
          const control = 'a, button, [role="button"], [data-link]';
          const target = c => c.dataset.link || (c.getAttribute('href') || '').replace(/^#board:/, '') || null;
          const linked = c => c.hasAttribute('data-link') || (c.getAttribute('href') || '').startsWith('#board:');
          // A click on a link, while presenting, shows its board.
          for (const f of K.frames) {
            const hook = () => f.contentDocument?.addEventListener('click', e => {
              const c = e.target.closest?.(control); if (!c || !linked(c)) return;
              const file = files.find(x => base(x) === target(c));
              if (file && window.kelpGoTo?.(file)) e.preventDefault();
            }, true);
            f.addEventListener('load', hook);
            if (f.contentDocument?.readyState === 'complete') hook();
          }
          // Goes To: the Mac's menu of the boards, the one it goes to ticked.
          function menu(board, id, now) {
            K.post({ kind: 'linkMenu', board, id, now: now || '',
              boards: files.filter(x => x !== board).map(x => ({ name: base(x), title: titleOf(x) })) });
          }
          window.kelpLinkTo = (board, id, name) => {
            const e = K.light(board)?.contentDocument?.querySelector('[data-id="' + CSS.escape(id) + '"]');
            if (!e) return;
            const a = e.tagName === 'A', attr = a ? 'href' : 'data-link';
            const value = name ? (a ? '#board:' : '') + name : null;
            if (value == null) e.removeAttribute(attr); else e.setAttribute(attr, value);
            K.post({ kind: 'attribute', board, id, name: attr, value });
            props?.redraw?.();
          };
          if (props) props.more = (props.more || []).concat([(e, id) => {
            if (!e.matches(control)) return [];
            const at = props.at(), now = linked(e) ? target(e) : null;
            const s = K.el('div', 'kelp-isec'), r = K.el('div', 'kelp-irow'), b = K.el('button', 'kelp-ipop');
            b.append(K.el('span', 'kelp-itok', now ? titleOf(files.find(x => base(x) === now) || now) : L.nowhere));
            b.onclick = () => menu(at.f.dataset.board, id, now);
            r.append(K.el('span', 'kelp-ilabel', L.goesTo), b, K.el('span'));
            s.append(K.el('div', 'kelp-ititle', L.flow), r);
            return [s];
          }]);
          // Check: the dead ends, once the design links one board to another.
          (window.kelpCheckMore = window.kelpCheckMore || []).push(out => {
            const lights = K.frames.filter(f => f.dataset.theme !== 'dark' && f.contentDocument?.body);
            const all = lights.flatMap(f => [...f.contentDocument.body.querySelectorAll(control)].map(c => ({ f, c })));
            if (!all.some(x => linked(x.c))) return;
            for (const { f, c } of all) {
              const href = c.getAttribute('href');
              const sends = ['submit', 'reset'].includes(c.getAttribute('type'));   // a form's, not the flow's
              if (linked(c) || (c.tagName === 'A' && href && href !== '#') || sends) continue;
              const words = (c.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 32);
              const id = c.getAttribute('data-id');
              const where = id ? ' in [data-id=' + id + ']' : '';
              out.push(f.dataset.board + ': «' + words + '»' + where + ' goes nowhere');
            }
          });
          const dead = new RegExp(DEAD), before = window.kelpIssueFix;
          window.kelpIssueFix = (line, row) => {
            before?.(line, row);
            const m = line.match(dead); if (!m) return;
            const [, board, id] = m, f = K.light(board);
            const e = f?.contentDocument?.querySelector('[data-id="' + CSS.escape(id) + '"]'); if (!e) return;
            const fix = K.el('div', 'kelp-ifix'), link = K.el('button', 'kelp-pill', L.link + '…');
            const agent = K.el('button', 'kelp-pill', L.toAgent);
            link.onclick = () => menu(board, id, null);
            agent.onclick = () => {
              K.setMode('mark');
              window.kelpMarks?.add(Object.assign({ kind: 'element', board, note: L.needsScreen }, K.describe(e)));
            };
            fix.append(link, agent);
            row.append(fix);
          };
        """
}
