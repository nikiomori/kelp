import Foundation

/// Edit's column for what the style rows don't reach (Open Design's Manual Edit): a link's address and where it
/// opens (`href`, `target`), a picture's words for VoiceOver (`alt`, or none for decoration), and how a flex or grid
/// container lays out its children (direction, distribution, alignment). Words go to the board as attributes
/// (`attribute`), layout as styles, both by hand like any change in Edit.
enum CanvasEditMore {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));" + CanvasTokens.source(labels: labels)
            + CanvasAccess.source(labels: labels) + CanvasBoardWidth.source(labels: labels)
            + CanvasLinks.source(labels: labels)
    }

    private static let body = """
          const K = window.kelpCanvas, props = window.kelpProps; if (!K || !props) return;
          const css = e => e.ownerDocument.defaultView.getComputedStyle(e);
          function row(label, control) {
            const r = K.el('div', 'kelp-irow');
            r.append(K.el('span', 'kelp-ilabel', label), control, K.el('span'));
            return r;
          }
          function section(title, rows) {
            const s = K.el('div', 'kelp-isec');
            s.append(K.el('div', 'kelp-ititle', title), ...rows);
            return s;
          }
          // Buttons, one per choice (a word, or an SF Symbol's name after "sym:", and its name as the tip), the one
          // `now` is on.
          function seg(choices, now, pick) {
            const s = K.el('span', 'kelp-iseg');
            for (const [value, glyph, tip] of choices) {
              const b = K.el('button', value === now ? 'on' : '');
              if (glyph.startsWith('sym:')) b.append(K.el('span', 'kelp-sym-' + glyph.slice(4).replaceAll('.', '-')));
              else b.textContent = glyph;
              b.title = tip; b.onclick = () => pick(value);
              s.append(b);
            }
            return s;
          }
          function words(value, done) {
            const box = K.el('label', 'kelp-ifld'), input = K.el('input');
            input.value = value;
            input.addEventListener('keydown', ev => { if (ev.key === 'Enter') input.blur(); ev.stopPropagation(); });
            input.addEventListener('change', () => done(input.value));
            box.append(input);
            return box;
          }
          // An attribute shown at once and written to the board's file.
          function attribute(e, id, name, value) {
            const at = props.at(); if (!at) return;
            if (value == null) e.removeAttribute(name); else e.setAttribute(name, value);
            K.post({ kind: 'attribute', board: at.f.dataset.board, id, name, value });
            props.redraw();
          }
          function link(e, id) {
            if (e.tagName !== 'A') return [];
            const opens = seg([['', L.no, L.here], ['_blank', L.yes, L.newWindow]],
              e.getAttribute('target') || '', v => attribute(e, id, 'target', v || null));
            return [section(L.link, [
              row(L.address, words(e.getAttribute('href') || '', v => attribute(e, id, 'href', v.trim() || null))),
              row(L.newWindow, opens)])];
          }
          function picture(e, id) {
            if (e.tagName !== 'IMG') return [];
            const alt = e.getAttribute('alt'), decoration = alt === '';
            const kind = seg([['words', L.no, L.words], ['decoration', L.yes, L.decorationTip]],
              decoration ? 'decoration' : 'words', v => attribute(e, id, 'alt', v === 'decoration' ? '' : null));
            const rows = [row(L.decoration, kind)];
            if (!decoration) rows.unshift(row(L.alt, words(alt || '', v => attribute(e, id, 'alt', v.trim() || null))));
            return [section(L.picture, rows)];
          }
          // A flex or grid container: where its children go, how they spread, how they line up across.
          function arrange(e) {
            const st = css(e), flex = /flex/.test(st.display);
            if (!flex && !/grid/.test(st.display)) return [];
            const rows = [];
            const ways = [['row', 'sym:arrow.right', L.across], ['column', 'sym:arrow.down', L.down]];
            if (flex) rows.push(row(L.direction, seg(ways, st.flexDirection.startsWith('column') ? 'column' : 'row',
              v => props.set('flex-direction', v))));
            rows.push(row(L.distribute, seg([['flex-start', 'sym:align.horizontal.left', L.start],
              ['center', 'sym:align.horizontal.center', L.middle], ['flex-end', 'sym:align.horizontal.right', L.end],
              ['space-between', 'sym:arrow.left.and.right', L.between]],
              st.justifyContent === 'normal' ? 'flex-start' : st.justifyContent,
              v => props.set('justify-content', v))));
            rows.push(row(L.alignItems, seg([['flex-start', 'sym:align.vertical.top', L.start],
              ['center', 'sym:align.vertical.center', L.middle], ['flex-end', 'sym:align.vertical.bottom', L.end],
              ['stretch', 'sym:arrow.up.and.down', L.stretch]],
              st.alignItems === 'normal' ? 'stretch' : st.alignItems, v => props.set('align-items', v))));
            return [section(L.arrange, rows)];
          }
          props.more = (props.more || []).concat([link, picture, arrange]);
        """
}
